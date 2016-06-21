module Network.Haskoin.Index.BlockChain where

import           Control.Concurrent               (threadDelay)
import           Control.Concurrent.Async.Lifted  (Async, async, wait, waitAny)
import qualified Control.Concurrent.RLock         as Lock (with)
import           Control.Concurrent.STM           (STM, atomically, retry)
import           Control.Concurrent.STM.TBMChan   (readTBMChan)
import           Control.Exception.Lifted         (throw)
import           Control.Monad                    (forM, forM_, forever, unless,
                                                   when, (<=<))
import           Control.Monad.Catch              (MonadMask)
import           Control.Monad.Logger             (MonadLoggerIO, logDebug,
                                                   logError, logInfo, logWarn)
import           Control.Monad.Reader             (asks)
import           Control.Monad.Trans              (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control      (MonadBaseControl,
                                                   liftBaseOp_)
import qualified Data.ByteString                  as BS (append, splitAt, tail)
import           Data.Conduit                     (Source, await, yield, ($$))
import           Data.Default                     (def)
import           Data.Either                      (rights)
import           Data.List                        (delete, nub, sortBy)
import qualified Data.Map                         as M (delete, elems, fromList,
                                                        insert, keys, lookup,
                                                        notMember, null, toList)
import           Data.Maybe                       (isNothing, listToMaybe)
import           Data.String.Conversions          (cs)
import           Data.Text                        (pack)
import           Data.Time.Clock                  (diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX            (getPOSIXTime)
import           Data.Word                        (Word32)
import qualified Database.LevelDB.Base            as L (BatchOp (Put), DB,
                                                        WriteBatch, get, put,
                                                        write)
import           Database.LevelDB.Iterator        (iterEntry, iterNext,
                                                   iterSeek, withIter)
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Index.HeaderTree
import           Network.Haskoin.Index.Peer
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util

blockSync :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
blockSync = do
    go []
  where
    go as
      | length as >= 5 = do
          (a, ()) <- waitAny as
          go (delete a as)
      | otherwise = do
          actionWhenSynced
          bh <- do
              -- Take the best block in the window, or look in the database
              bhM <- atomicallyNodeT bestBlockInWindow
              maybe bestIndexedBlock return bhM
          -- Wait either for a new block to arrive
          $(logDebug) "Waiting for a new block..."
          _ <- atomicallyNodeT $ waitNewBlock $ nodeHash bh
          $(logDebug) $ pack $ unwords
              [ "Requesting download from block"
              , cs $ blockHashToHex (nodeHash bh)
              ]
          -- Get the list of blocks to download from our headers
          action <- runSqlNodeT $ do
              bestH <- getBestBlock
              getBlockWindow bestH bh 500
          case actionNodes action of
              [] -> do
                  $(logError) "BlockChainAction was empty. Retrying ..."
                  -- Sleep 10 seconds and retry
                  liftIO $ threadDelay $ 10*1000000
                  go as
              ns -> do
                  let head   = nodeHash $ last ns
                      height = nodeBlockHeight $ last ns
                      bw = BlockWindow Nothing Nothing height 0 False $ last ns
                  -- Save an entry into the window
                  atomicallyNodeT $ insertBlockWindow head bw
                  a <- async $ blockDownload action
                  go (a:as)

bestBlockInWindow :: NodeT STM (Maybe NodeBlock)
bestBlockInWindow = do
    bwMap <- readTVarS sharedBlockWindow
    -- Sort by descending height
    let s a b = blockWindowHeight b `compare` blockWindowHeight a
    return $ listToMaybe $ map blockWindowNode $ sortBy s $ M.elems bwMap

-- Download the given BlockChainAction. It will retry if the download times out.
blockDownload
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => BlockChainAction
    -> NodeT m ()
blockDownload action = do
    -- Wait for a peer available for block downloads
    (pid, PeerSession{..}) <- atomicallyNodeT $ do
        (pid, sess) <- waitFreePeer
        updateBlockWindow head $
            \bw -> bw{ blockWindowPeerId = Just pid }
        return (pid, sess)
    $(logInfo) $ formatPid pid peerSessionHost $ unwords
        [ "Found a peer to download blocks at height", show height ]

    -- save the starting time
    now <- liftIO getCurrentTime
    atomicallyNodeT $ updateBlockWindow head $
        \bw -> bw{ blockWindowTimestamp = Just now }

    -- index the blocks
    startTime <- liftIO getCurrentTime
    (resM, cnt) <-
        peerBlockSource pid peerSessionHost (map nodeHash ns) $$ indexBlocks
    endTime <- liftIO getCurrentTime
    let diff = diffUTCTime endTime startTime

    -- Check if the full batch was downloaded
    if (headerHash . blockHeader <$> resM) == Just head
        then withDBLock $ do
            logBlockChainAction action
            $(logInfo) $ formatPid pid peerSessionHost $ unwords
                [ "Blocks indexed at height"
                , show height, "in", show diff
                , "(", show cnt, "values", ")"
                ]
            bwDone <- atomicallyNodeT $ do
                updateBlockWindow head $ \bw ->
                    bw{ blockWindowComplete = True
                      , blockWindowPeerId   = Nothing
                      }
                cleanBlockWindow
            case bwDone of
                -- Out of order blocks are not a problem
                [] -> $(logInfo) $ formatPid pid peerSessionHost $
                    unwords [ "Out of order indexed blocks at height"
                            , show height
                            ]
                _  -> do
                    let bh = fst $ last bwDone
                    nodeM <- runSqlNodeT $ getBlockByHash bh
                    case nodeM of
                        Just node -> do
                            setBestIndexedBlock node
                            $(logInfo) $ formatPid pid peerSessionHost $
                                unwords [ "Updating best indexed block to"
                                        , cs $ blockHashToHex bh
                                        , "at height"
                                        , show $ nodeBlockHeight node
                                        ]
                        _ -> $(logWarn) $ formatPid pid peerSessionHost $
                            unwords [ "Could not set best indexed block"
                                    , cs $ blockHashToHex bh
                                    ]
        else do
            $(logWarn) $ formatPid pid peerSessionHost $
                unwords [ "Peer sent us incomplete block list for request"
                        , cs $ blockHashToHex head
                        , "at height"
                        , show height
                        ]
            atomicallyNodeT $ updateBlockWindow head $ \bw ->
                bw { blockWindowPeerId    = Nothing
                   , blockWindowTimestamp = Nothing
                   , blockWindowCount     = 0
                   , blockWindowComplete  = False
                   }
            blockDownload action
  where
    ns     = actionNodes action
    head   = nodeHash $ last ns
    height = nodeBlockHeight $ last ns
    indexBlocks = go Nothing 0
    go prevM cnt = await >>= \resM -> case resM of
        Just b -> do
            lift $ atomicallyNodeT $ updateBlockWindow head $ \bw ->
                bw{ blockWindowCount = blockWindowCount bw + 1 }
            cnt' <- lift $ indexBlock b
            go resM $ cnt + cnt'
        _ -> return (prevM, cnt)
    logBlockChainAction action = case action of
        BestChain nodes -> $(logInfo) $ pack $ unwords
            [ "Indexed best chain at height"
            , show $ nodeBlockHeight $ last nodes
            , "(", cs $ blockHashToHex $ nodeHash $ last nodes
            , ")"
            ]
        ChainReorg _ o n -> $(logInfo) $ pack $ unlines $
            [ "Indexed chain reorg."
            , "Orphaned blocks:"
            ]
            ++ map (("  " ++) . cs . blockHashToHex . nodeHash) o
            ++ [ "New blocks:" ]
            ++ map (("  " ++) . cs . blockHashToHex . nodeHash) n
            ++ [ unwords [ "Best block chain height"
                        , show $ nodeBlockHeight $ last n
                        ]
            ]
        SideChain n -> $(logWarn) $ pack $ unlines $
            "Indexed side chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n
        KnownChain n -> $(logWarn) $ pack $ unlines $
            "Indexed Known chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n

-- Remove completed block windows at the start
cleanBlockWindow :: NodeT STM [(BlockHash, BlockWindow)]
cleanBlockWindow = do
    bwMap <- readTVarS sharedBlockWindow
    let s (_,a) (_,b) = (blockWindowHeight a) `compare` (blockWindowHeight b)
        bwSorted = sortBy s $ M.toList bwMap
        (bwDone, bwRest) = span (blockWindowComplete . snd) bwSorted
    writeTVarS sharedBlockWindow $ M.fromList bwRest
    return bwDone

peerBlockSource
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => PeerId
    -> PeerHost
    -> [BlockHash]
    -> Source (NodeT m) Block
peerBlockSource pid ph bids = do
    let vs = map (InvVector InvBlock . getBlockHash) bids
    $(logInfo) $ formatPid pid ph $ unwords
        [ "Requesting", show $ length bids, "blocks" ]
    -- Request a block batch download
    sessM <- lift . atomicallyNodeT $ do
        _ <- trySendMessage pid $ MGetData $ GetData vs
        tryGetPeerSession pid
    case sessM of
        Just PeerSession{..} -> goSource peerSessionBlockChan bids
        _ -> return ()
  where
    goSource _ [] = return ()
    goSource chan rBids = do
        -- Read the channel or disconnect the peer after waiting for 2 minutes
        resM <- lift $ raceTimeout 120
                    (disconnectPeer pid ph)
                    (liftIO . atomically $ readTBMChan chan)
        case resM of
            Right (Just block) -> do
                let mBid = headerHash $ blockHeader block
                $(logDebug) $ formatPid pid ph $ unwords
                    [ "Processing block", cs $ blockHashToHex mBid ]
                -- Check if we were expecting this block
                if mBid `elem` rBids
                    then yield block >> goSource chan (mBid `delete` rBids)
                    else lift $ do
                        -- If we were not expecting this block, do not
                        -- yield the block and close the source
                        $(logError) $ formatPid pid ph $ unwords
                            [ "Peer sent us an unexpected block hash"
                            , cs $ blockHashToHex mBid
                            ]
                        disconnectPeer pid ph
            -- We received everything
            Right _ -> return ()
            -- Timeout reached
            _ -> $(logWarn) $ formatPid pid ph
                    "Block channel closed unexpectedly"

actionWhenSynced :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
actionWhenSynced =
    -- Aquire the header syncing lock to prune without screwing stuff up
    asks sharedSyncLock >>= \lock -> liftBaseOp_ (Lock.with lock) $ do
    -- Check if we are synced
    (synced, bestHead) <- areBlocksSynced
    initialSync <- atomicallyNodeT $ readTVarS sharedInitialSync
    when synced $ do
        $(logInfo) $ pack $ unwords
            [ "Blocks are in sync with the"
            , "network at height", show $ nodeBlockHeight bestHead
            ]
        runSqlNodeT $ pruneChain bestHead
        -- Do a mempool sync on the first block sync
        unless initialSync $ do
            atomicallyNodeT $ do
                sendMessageAll MMempool
                writeTVarS sharedInitialSync True
            $(logInfo) "Requesting a mempool sync"

areBlocksSynced :: (MonadIO m, MonadBaseControl IO m)
                => NodeT m (Bool, NodeBlock)
areBlocksSynced = withDBLock $ do
    (headersSynced, bestHead) <- areHeadersSynced
    bestBlock <- bestIndexedBlock
    return ( headersSynced && nodeHash bestBlock == nodeHash bestHead
           , bestHead
           )

-- Check if the block headers are synced with the network height
areHeadersSynced :: (MonadIO m, MonadBaseControl IO m)
                 => NodeT m (Bool, NodeBlock)
areHeadersSynced = withDBLock $ do
    bestHead <- runSqlNodeT getBestBlock
    netHeight <- atomicallyNodeT $ readTVarS sharedNetworkHeight
    -- If netHeight == 0 then we did not connect to any peers yet
    return ( nodeBlockHeight bestHead >= netHeight && netHeight > 0
           , bestHead
           )

-- Wait for a new block to be available for download
waitNewBlock :: BlockHash -> NodeT STM ()
waitNewBlock bh = do
    node <- readTVarS sharedBestHeader
    -- We have more blocks to download
    unless (bh /= node) $ lift retry

processTickles :: (MonadLoggerIO m, MonadBaseControl IO m)
               => NodeT m ()
processTickles = forever $ do
    $(logDebug) $ pack "Waiting for a block tickle ..."
    (pid, ph, tickle) <- atomicallyNodeT waitTickle
    $(logInfo) $ formatPid pid ph $ unwords
        [ "Received block tickle", cs $ blockHashToHex tickle ]
    heightM <- fmap nodeBlockHeight <$> runSqlNodeT (getBlockByHash tickle)
    case heightM of
        Just height -> do
            $(logInfo) $ formatPid pid ph $ unwords
                [ "The block tickle", cs $ blockHashToHex tickle
                , "is already connected"
                ]
            updatePeerHeight pid ph height
        _ -> do
            $(logDebug) $ formatPid pid ph $ unwords
                [ "The tickle", cs $ blockHashToHex tickle
                , "is unknown. Requesting a peer header sync."
                ]
            peerHeaderSyncFull pid ph `catchAny` const (disconnectPeer pid ph)
            newHeightM <-
                fmap nodeBlockHeight <$> runSqlNodeT (getBlockByHash tickle)
            case newHeightM of
                Just height -> do
                    $(logInfo) $ formatPid pid ph $ unwords
                        [ "The block tickle", cs $ blockHashToHex tickle
                        , "was connected successfully"
                        ]
                    updatePeerHeight pid ph height
                _ -> $(logWarn) $ formatPid pid ph $ unwords
                    [ "Could not find the height of block tickle"
                    , cs $ blockHashToHex tickle
                    ]
  where
    updatePeerHeight pid ph height = do
        $(logInfo) $ formatPid pid ph $ unwords
            [ "Updating peer height to", show height ]
        atomicallyNodeT $ do
            modifyPeerSession pid $ \s ->
                s{ peerSessionHeight = height }
            updateNetworkHeight

waitTickle :: NodeT STM (PeerId, PeerHost, BlockHash)
waitTickle = do
    tickleChan <- asks sharedTickleChan
    resM <- lift $ readTBMChan tickleChan
    case resM of
        Just res -> return res
        _ -> throw $ NodeException "tickle channel closed unexpectedly"

headerSync :: (MonadLoggerIO m, MonadBaseControl IO m)
           => NodeT m ()
headerSync = do
    -- Start the header sync
    $(logInfo) "Starting the header sync"
    (pid, PeerSession{..}) <- atomicallyNodeT waitFreePeer

    $(logDebug) $ formatPid pid peerSessionHost "Syncing headers from this peer"

    continue <- catchAny
        (peerHeaderSyncFull pid peerSessionHost >> return False) $ \e -> do
            $(logError) $ pack $ show e
            disconnectPeer pid peerSessionHost >> return True

    -- Recurse if the headersync crashed
    if continue then headerSync else
        $(logDebug) "Header sync complete"

-- Sync all the headers from a given peer
peerHeaderSyncFull :: (MonadLoggerIO m, MonadBaseControl IO m)
                   => PeerId
                   -> PeerHost
                   -> NodeT m ()
peerHeaderSyncFull pid ph =
    go Nothing
  where
    go prevM = peerHeaderSync pid ph prevM >>= \actionM -> case actionM of
        Just _  -> go actionM
        Nothing -> do
            (synced, bestHead) <- areHeadersSynced
            when synced $ $(logInfo) $ formatPid pid ph $ unwords
                [ "Block headers are in sync with the"
                , "network at height", show $ nodeBlockHeight bestHead
                ]

-- | Sync one batch of headers from the given peer. Accept the result of a
-- previous peerHeaderSync to correctly compute block locators in the
-- presence of side chains.
peerHeaderSync :: (MonadLoggerIO m, MonadBaseControl IO m)
               => PeerId
               -> PeerHost
               -> Maybe BlockChainAction
               -> NodeT m (Maybe BlockChainAction)
peerHeaderSync pid ph prevM = do
    $(logDebug) $ formatPid pid ph "Waiting for the HeaderSync lock"
    -- Aquire the header syncing lock
    lock <- asks sharedSyncLock
    liftBaseOp_ (Lock.with lock) $ do

        best <- runSqlNodeT getBestBlock

        -- Retrieve the block locator
        loc <- case prevM of
            Just (KnownChain ns) -> do
                $(logDebug) $ formatPid pid ph "Building a known chain locator"
                runSqlNodeT $ blockLocator $ last ns
            Just (SideChain ns) -> do
                $(logDebug) $ formatPid pid ph "Building a side chain locator"
                runSqlNodeT $ blockLocator $ last ns
            Just (BestChain ns) -> do
                $(logDebug) $ formatPid pid ph "Building a best chain locator"
                runSqlNodeT $ blockLocator $ last ns
            Just (ChainReorg _ _ ns) -> do
                $(logDebug) $ formatPid pid ph "Building a reorg locator"
                runSqlNodeT $ blockLocator $ last ns
            Nothing -> do
                $(logDebug) $ formatPid pid ph "Building a locator to best"
                runSqlNodeT $ blockLocator best

        $(logDebug) $ formatPid pid ph $ unwords
            [ "Requesting headers with block locator of size"
            , show $ length loc
            , "Start block:", cs $ blockHashToHex $ head loc
            , "End block:",   cs $ blockHashToHex $ last loc
            ]

        -- Send a GetHeaders message to the peer
        atomicallyNodeT $ sendMessage pid $ MGetHeaders $ GetHeaders 0x01 loc z

        $(logDebug) $ formatPid pid ph "Waiting 2 minutes for headers..."

        -- Wait 120 seconds for a response or time out
        continueE <- raceTimeout 120 (disconnectPeer pid ph) (waitHeaders best)

        -- Return True if we can continue syncing from this peer
        return $ either (const Nothing) id continueE
  where
    z = "0000000000000000000000000000000000000000000000000000000000000000"
    -- Wait for the headers to be available
    waitHeaders best = do
        (rPid, headers) <- atomicallyNodeT $ takeTMVarS sharedHeaders
        if rPid == pid
            then processHeaders best headers
            else waitHeaders best
    processHeaders _ (Headers []) = do
        $(logDebug) $ formatPid pid ph
            "Received empty headers. Finished downloading headers."
        -- Do not continue the header download
        return Nothing
    processHeaders best (Headers hs) = do
        $(logDebug) $ formatPid pid ph $ unwords
            [ "Received", show $ length hs, "headers."
            , "Start blocks:", cs $ blockHashToHex $ headerHash $ fst $ head hs
            , "End blocks:", cs $ blockHashToHex $ headerHash $ fst $ last hs
            ]
        now <- round <$> liftIO getPOSIXTime
        actionE <- runSqlNodeT $ connectHeaders best (map fst hs) now
        case actionE of
            Left err -> do
                $(logError) $ formatPid pid ph err
                return Nothing
            Right action -> case actionNodes action of
                [] -> do
                    $(logWarn) $ formatPid pid ph $ unwords
                        [ "Received an empty blockchain action:", show action ]
                    return Nothing
                nodes -> do
                    $(logDebug) $ formatPid pid ph $ unwords
                        [ "Received", show $ length nodes
                        , "nodes in the action"
                        ]
                    let height = nodeBlockHeight $ last nodes
                    case action of
                        KnownChain _ ->
                            $(logInfo) $ formatPid pid ph $ unwords
                                [ "KnownChain headers received"
                                , "up to height", show height
                                ]
                        SideChain _ ->
                            $(logInfo) $ formatPid pid ph $ unwords
                                [ "SideChain headers connected successfully"
                                , "up to height", show height
                                ]
                        -- Headers extend our current best head
                        _ -> do
                            $(logInfo) $ formatPid pid ph $ unwords
                                [ "Best headers connected successfully"
                                , "up to height", show height
                                ]
                            -- Notify other threads that a new header is here
                            atomicallyNodeT $ writeTVarS sharedBestHeader $
                                nodeHash $ last nodes
                    -- If we received less than 2000 headers, we are done
                    -- syncing from this peer and we return Nothing.
                    return $ if length hs < 2000
                        then Nothing
                        else Just action

{- LevelDB indexing database -}

initLevelDB :: (MonadBaseControl IO m, MonadIO m) => NodeT m ()
initLevelDB = withDBLock $ do
    db <- asks sharedLevelDB
    resM <- liftIO $ L.get db def "0-bestindexedblock"
    when (isNothing resM) $ setBestIndexedBlock genesisBlock

indexBlock :: (MonadLoggerIO m, MonadBaseControl IO m) => Block -> NodeT m Int
indexBlock b@(Block _ txs) = do
    db <- asks sharedLevelDB
    $(logDebug) $ pack $ unwords
        [ "Indexing block"
        , cs $ blockHashToHex $ headerHash $ blockHeader b
        , "containing", show (length txs), "txs"
        ]
    let batch = concat $ map txBatch txs
    withDBLock $ L.write db def batch
    return $ length batch

indexTx :: (MonadLoggerIO m, MonadBaseControl IO m) => Tx -> NodeT m Int
indexTx tx = do
    db <- asks sharedLevelDB
    $(logDebug) $ pack $ unwords
        [ "Indexing tx"
        , cs $ txHashToHex $ txHash tx
        ]
    let batch = txBatch tx
    withDBLock $ L.write db def batch
    return $ length batch

txBatch :: Tx -> L.WriteBatch
txBatch tx =
    map (\a -> L.Put (key a) val) txAddrs
  where
    (l, val) = BS.splitAt 16 $ encode' txid
    key a = encode' a `BS.append` l
    txid = txHash tx
    txAddrs = rights addrs
    addrs = map fIn (txIn tx) ++ map fOut (txOut tx)
    fIn  = inputAddress <=< (decodeInputBS . scriptInput)
    fOut = outputAddress <=< (decodeOutputBS . scriptOutput)

getAddressTxs :: (MonadLoggerIO m, MonadBaseControl IO m, MonadMask m)
              => Address -> NodeT m [TxHash]
getAddressTxs addr = do
    db <- asks sharedLevelDB
    $(logDebug) $ pack $ unwords
        [ "Fetching indexed transactions for address"
        , cs $ addrToBase58 addr
        ]
    withDBLock $ withIter db def $ \iter -> do
        iterSeek iter addrPref
        go iter []
  where
    addrPref = encode' addr
    go iter acc = iterEntry iter >>= \entM -> case entM of
        Just (key, valTxid) -> do
            let (keyAddr, keyTxid) = BS.splitAt 16 key
            if keyAddr == addrPref
               then do
                    let txid = decode' $ keyTxid `BS.append` valTxid
                    iterNext iter
                    go iter (txid:acc)
               else return acc
        _ -> return acc

bestIndexedBlock :: (MonadBaseControl IO m, MonadIO m) => NodeT m NodeBlock
bestIndexedBlock = withDBLock $ do
    db <- asks sharedLevelDB
    -- Start the key with 0 as it is smaller than all base58 characters
    resM <- liftIO $ L.get db def "0-bestindexedblock"
    case resM of
        Just bs -> return $ decode' bs
        _ -> error "No best indexed block in the database"

setBestIndexedBlock :: (MonadBaseControl IO m, MonadIO m)
                    => NodeBlock -> NodeT m ()
setBestIndexedBlock node = withDBLock $ do
    db <- asks sharedLevelDB
    L.put db def "0-bestindexedblock" $ encode' node

