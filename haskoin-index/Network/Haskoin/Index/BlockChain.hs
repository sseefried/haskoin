module Network.Haskoin.Index.BlockChain where

import           Control.Concurrent               (threadDelay)
import           Control.Concurrent.STM           (STM, atomically, retry)
import qualified Control.Concurrent.STM.Lock      as Lock (with)
import           Control.Concurrent.STM.TBMChan   (readTBMChan)
import           Control.Exception.Lifted         (throw)
import           Control.Monad                    (forM, forM_, forever, unless,
                                                   when, (<=<))
import           Control.Monad.Logger             (MonadLoggerIO, logDebug,
                                                   logError, logInfo, logWarn)
import           Control.Monad.Reader             (asks)
import           Control.Monad.Trans              (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control      (MonadBaseControl,
                                                   liftBaseOp_)
import qualified Data.ByteString                  as BS (append, splitAt, take)
import           Data.Conduit                     (Source, await, yield, ($$))
import           Data.Default                     (def)
import           Data.Either                      (rights)
import           Data.List                        (delete, nub)
import qualified Data.Map                         as M (delete, keys, lookup,
                                                        null)
import           Data.Maybe                       (isNothing, listToMaybe)
import           Data.String.Conversions          (cs)
import           Data.Text                        (pack)
import           Data.Time.Clock                  (diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX            (getPOSIXTime)
import           Data.Word                        (Word32)
import qualified Database.LevelDB.Base            as L (BatchOp (Put), DB,
                                                        WriteBatch, get, put,
                                                        write)
import           Network.Haskoin.Block
import           Network.Haskoin.Index.HeaderTree
import           Network.Haskoin.Index.Peer
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util

blockDownload
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => Word32
    -> NodeT m ()
blockDownload batchSize = do
    blockCheckSync
    bh <- withLevelDB bestIndexedBlock
    -- Wait either for a new block to arrive
    $(logDebug) "Waiting for a new block..."
    _ <- atomicallyNodeT $ waitNewBlock $ nodeHash bh
    $(logDebug) $ pack $ unwords
        [ "Requesting download from block"
        , cs $ blockHashToHex (nodeHash bh)
        , "and batch size", show batchSize
        ]
    -- Get the list of blocks to download from our headers
    action <- runSqlNodeT $ do
        bestH <- getBestBlock
        getBlockWindow bestH bh batchSize
    case actionNodes action of
        [] -> do
            $(logError) "BlockChainAction was empty. Retrying ..."
            -- Sleep 10 seconds and retry
            liftIO $ threadDelay $ 10*1000000
        ns -> do
            -- Wait for a peer available for block downloads
            (pid, PeerSession{..}) <- atomicallyNodeT $ waitDownloadPeer $
                nodeBlockHeight $ last ns
            $(logDebug) $ formatPid pid peerSessionHost
                "Found a peer to download blocks"
            -- index the blocks
            logBlockChainAction action
            startTime <- liftIO getCurrentTime
            (resM, cnt) <-
                peerBlockSource pid peerSessionHost (map nodeHash ns) $$
                indexBlocks
            endTime <- liftIO getCurrentTime
            let diff = diffUTCTime endTime startTime
            -- Update the best block
            case (action, resM) of
                (BestChain _, Just b) -> do
                    nodeM <-  runSqlNodeT $ getBlockByHash $
                        headerHash $ blockHeader b
                    case nodeM of
                        Just node -> do
                            withLevelDB $ setBestIndexedBlock node
                            $(logInfo) $ formatPid pid peerSessionHost $
                                unwords [ "Blocks indexed up to height"
                                        , show $ nodeBlockHeight node
                                        , "in", show diff
                                        , "(", show cnt, "values", ")"
                                        ]
                        _ -> $(logWarn) $ formatPid pid peerSessionHost $
                            unwords [ "Could not set best indexed block"
                                    , cs $ blockHashToHex $
                                        headerHash $ blockHeader b
                                    ]
                _ -> return ()
    blockDownload batchSize
  where
    indexBlocks = go Nothing 0
    go prevM cnt = await >>= \resM -> case resM of
        Just b -> do
            cnt' <- lift $ indexBlock b
            go resM $ cnt + cnt'
        _ -> return (prevM, cnt)
    logBlockChainAction action = case action of
        BestChain nodes -> $(logInfo) $ pack $ unwords
            [ "Best chain height"
            , show $ nodeBlockHeight $ last nodes
            , "(", cs $ blockHashToHex $ nodeHash $ last nodes
            , ")"
            ]
        ChainReorg _ o n -> $(logInfo) $ pack $ unlines $
            [ "Chain reorg."
            , "Orphaned blocks:"
            ]
            ++ map (("  " ++) . cs . blockHashToHex . nodeHash) o
            ++ [ "New blocks:" ]
            ++ map (("  " ++) . cs . blockHashToHex . nodeHash) n
            ++ [ unwords [ "Best merkle chain height"
                        , show $ nodeBlockHeight $ last n
                        ]
            ]
        SideChain n -> $(logWarn) $ pack $ unlines $
            "Side chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n
        KnownChain n -> $(logWarn) $ pack $ unlines $
            "Known chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n

waitDownloadPeer :: BlockHeight -> NodeT STM (PeerId, PeerSession)
waitDownloadPeer height = do
    pidM     <- readTVarS sharedHeaderPeer
    allPeers <- getPeersAtHeight (>= height)
    let f (pid,_) = Just pid /= pidM
        -- Filter out the peer syncing headers (if there is one)
        peers = filter f allPeers
    case peers of
        (res:_) -> return res
        _       -> lift retry

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
                -- Check if we were expecting this merkle block
                if mBid `elem` rBids
                    then yield block >> goSource chan (mBid `delete` rBids)
                    else lift $ do
                        -- If we were not expecting this merkle block, do not
                        -- yield the merkle block and close the source
                        $(logError) $ formatPid pid ph $ unwords
                            [ "Peer sent us an unexpected block hash"
                            , cs $ blockHashToHex mBid
                            ]
                        disconnectPeer pid ph
            -- We received everything
            Right _ -> return ()
            -- Timeout reached
            _ -> $(logWarn) $ formatPid pid ph
                    "Merkle channel closed unexpectedly"

blockCheckSync :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
blockCheckSync = do
    -- Check if we are synced
    (synced, _, bestHead) <- areBlocksSynced
    mempool <- atomicallyNodeT $ readTVarS sharedMempool
    when synced $ do
        $(logInfo) $ pack $ unwords
            [ "Blocks are in sync with the"
            , "network at height", show $ nodeBlockHeight bestHead
            ]
        -- Do a mempool sync on the first merkle sync
        unless mempool $ do
            atomicallyNodeT $ do
                sendMessageAll MMempool
                writeTVarS sharedMempool True
            $(logInfo) "Requesting a mempool sync"

areBlocksSynced :: (MonadIO m, MonadBaseControl IO m)
                => NodeT m (Bool, NodeBlock, NodeBlock)
areBlocksSynced = do
    (headersSynced, bestHead) <- areHeadersSynced
    bestBlock <- withLevelDB bestIndexedBlock
    return ( headersSynced && nodeHash bestBlock == nodeHash bestHead
           , bestBlock
           , bestHead
           )

-- Check if the block headers are synced with the network height
areHeadersSynced :: (MonadIO m, MonadBaseControl IO m)
                 => NodeT m (Bool, NodeBlock)
areHeadersSynced = do
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
    -- We have more merkle blocks to download
    unless (bh /= nodeHash node) $ lift retry

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
    $(logDebug) "Syncing more headers. Finding the best peer..."
    (pid, PeerSession{..}) <- atomicallyNodeT $ do
        peers <- getPeersAtNetHeight
        case listToMaybe peers of
            Just res@(pid,_) -> do
                -- Save the header syncing peer
                writeTVarS sharedHeaderPeer $ Just pid
                return res
            _ -> lift retry

    $(logDebug) $ formatPid pid peerSessionHost "Found a peer to sync headers"

    -- Run a maximum of 10 header downloads with this peer.
    -- Then we re-evaluate the best peer
    continue <- catchAny (peerHeaderSyncLimit pid peerSessionHost 10) $
        \e -> do
            $(logError) $ pack $ show e
            disconnectPeer pid peerSessionHost >> return True

    -- Reset the header syncing peer
    atomicallyNodeT $ writeTVarS sharedHeaderPeer Nothing

    -- Check if we should continue the header sync
    if continue then headerSync else do
        (synced, bestHead) <- areHeadersSynced
        if synced
            then do
                -- Check if blocks are synced
                blockCheckSync
                $(logInfo) $ formatPid pid peerSessionHost $ unwords
                    [ "Block headers are in sync with the"
                    , "network at height", show $ nodeBlockHeight bestHead
                    ]
            -- Continue the download if we are not yet synced
            else headerSync

peerHeaderSyncLimit :: (MonadLoggerIO m, MonadBaseControl IO m)
                    => PeerId
                    -> PeerHost
                    -> Int
                    -> NodeT m Bool
peerHeaderSyncLimit pid ph initLimit
    | initLimit < 1 = error "Limit must be at least 1"
    | otherwise = go initLimit Nothing
  where
    go limit prevM = peerHeaderSync pid ph prevM >>= \actionM -> case actionM of
        Just action ->
            -- If we received a side chain or a known chain, we want to
            -- continue szncing from this peer even if the limit has been
            -- reached.
            if limit > 1 || isSideChain action || isKnownChain action
                then go (limit - 1) actionM
                -- We got a Just, so we can continue the download from
                -- this peer
                else return True
        _ -> return False

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
                            atomicallyNodeT $
                                writeTVarS sharedBestHeader $ last nodes
                    -- If we received less than 2000 headers, we are done
                    -- syncing from this peer and we return Nothing.
                    return $ if length hs < 2000
                        then Nothing
                        else Just action

-- Source of all transaction broadcasts
txSource :: (MonadLoggerIO m, MonadBaseControl IO m)
         => Source (NodeT m) Tx
txSource = do
    chan <- lift $ asks sharedTxChan
    $(logDebug) "Waiting to receive a transaction..."
    resM <- liftIO $ atomically $ readTBMChan chan
    case resM of
        Just (pid, ph, tx) -> do
            $(logInfo) $ formatPid pid ph $ unwords
                [ "Received inbound transaction broadcast"
                , cs $ txHashToHex $ txHash tx
                ]
            yield tx >> txSource
        _ -> $(logError) "Tx channel closed unexpectedly"

handleGetData :: (MonadLoggerIO m, MonadBaseControl IO m)
              => (TxHash -> m (Maybe Tx))
              -> NodeT m ()
handleGetData handler = forever $ do
    $(logDebug) "Waiting for GetData transaction requests..."
    -- Wait for tx GetData requests to be available
    txids <- atomicallyNodeT $ do
        datMap <- readTVarS sharedTxGetData
        if M.null datMap then lift retry else return $ M.keys datMap
    forM (nub txids) $ \tid -> lift (handler tid) >>= \txM -> do
        $(logDebug) $ pack $ unwords
            [ "Processing GetData txid request", cs $ txHashToHex tid ]
        pidsM <- atomicallyNodeT $ do
            datMap <- readTVarS sharedTxGetData
            writeTVarS sharedTxGetData $ M.delete tid datMap
            return $ M.lookup tid datMap
        case (txM, pidsM) of
            -- Send the transaction to the required peers
            (Just tx, Just pids) -> forM_ pids $ \(pid, ph) -> do
                $(logDebug) $ formatPid pid ph $ unwords
                    [ "Sending tx", cs $ txHashToHex tid, "to peer" ]
                atomicallyNodeT $ trySendMessage pid $ MTx tx
            _ -> return ()

{- LevelDB indexing database -}

withLevelDB :: MonadBaseControl IO m => (L.DB -> NodeT m a) -> NodeT m a
withLevelDB action = do
    lock <- asks sharedSyncLock
    db   <- asks sharedLevelDB
    liftBaseOp_ (Lock.with lock) $ action db

initLevelDB :: (MonadBaseControl IO m, MonadIO m) => L.DB -> NodeT m ()
initLevelDB db = do
    resM <- L.get db def "0-bestindexedblock"
    when (isNothing resM) $ setBestIndexedBlock genesisBlock db

indexBlock :: (MonadLoggerIO m, MonadBaseControl IO m) => Block -> NodeT m Int
indexBlock b@(Block _ txs) = do
    $(logDebug) $ pack $ unwords
        [ "Indexing block"
        , cs $ blockHashToHex $ headerHash $ blockHeader b
        , "containing", show (length txs), "txs"
        ]
    let batch = concat $ map indexTx txs
    withLevelDB $ \db -> L.write db def batch
    return $ length batch

indexTx :: Tx -> L.WriteBatch
indexTx tx@(Tx _ txIns txOuts _) =
    batch
  where
    batch = map (\a -> L.Put (key a) val) txAddrs
    (l, val) = BS.splitAt 16 $ encode' txid
    key a = (BS.take 16 (encode' a)) `BS.append` l
    txid = txHash tx
    txAddrs = rights $ map fIn txIns ++ map fOut txOuts
    fIn  = inputAddress <=< (decodeInputBS . scriptInput)
    fOut = outputAddress <=< (decodeOutputBS . scriptOutput)

bestIndexedBlock :: (MonadBaseControl IO m, MonadIO m)
                 => L.DB -> NodeT m NodeBlock
bestIndexedBlock db = do
    -- Start the key with 0 as it is smaller than all base58 characters
    resM <- L.get db def "0-bestindexedblock"
    case resM of
        Just bs -> return $ decode' bs
        _ -> error "No best indexed block in the database"

setBestIndexedBlock :: (MonadBaseControl IO m, MonadIO m)
                    => NodeBlock -> L.DB -> NodeT m ()
setBestIndexedBlock node db = L.put db def "0-bestindexedblock" $ encode' node

