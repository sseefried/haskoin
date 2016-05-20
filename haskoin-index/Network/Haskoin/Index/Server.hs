module Network.Haskoin.Index.Server
( runIndex
, nodeStatus
, broadcastTxs
) where

import           Control.Concurrent.Async.Lifted       (async, mapConcurrently,
                                                        waitAnyCancel)
import           Control.Exception.Lifted              (ErrorCall (..),
                                                        SomeException (..),
                                                        catches)
import qualified Control.Exception.Lifted              as E (Handler (..))
import           Control.Monad                         (forM_, forever, void,
                                                        when)
import           Control.Monad.Logger                  (MonadLoggerIO,
                                                        filterLogger, logDebug,
                                                        logError, logInfo,
                                                        runStdoutLoggingT)
import           Control.Monad.Reader                  (asks)
import           Control.Monad.Trans                   (liftIO)
import           Control.Monad.Trans.Control           (MonadBaseControl,
                                                        liftBaseOpDiscard)
import           Control.Monad.Trans.Resource          (runResourceT)
import           Data.Aeson                            (decode, encode)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString.Lazy                  as BL (fromStrict,
                                                              toStrict)
import           Data.Conduit                          (awaitForever, ($$))
import qualified Data.HashMap.Strict                   as H (lookup)
import           Data.List.NonEmpty                    (NonEmpty ((:|)))
import           Data.Maybe                            (fromJust, fromMaybe,
                                                        isJust)
import           Data.String.Conversions               (cs)
import           Data.Text                             (pack)
import qualified Database.LevelDB.Base                 as L (Options (..),
                                                             defaultOptions,
                                                             open)
import           Database.Persist.Sql                  (ConnectionPool,
                                                        runMigration)
import           Network.Haskoin.Constants
import           Network.Haskoin.Index.BlockChain
import           Network.Haskoin.Index.Database
import           Network.Haskoin.Index.HeaderTree
import           Network.Haskoin.Index.Peer
import           Network.Haskoin.Index.Server.Handlers
import           Network.Haskoin.Index.Settings
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           System.Posix.Daemon                   (Redirection (ToFile),
                                                        runDetached)
import           System.ZMQ4                           (Context, KeyFormat (..),
                                                        Rep (..), Socket, bind,
                                                        receive, receiveMulti,
                                                        send, sendMulti,
                                                        setCurveSecretKey,
                                                        setCurveServer,
                                                        withContext, withSocket,
                                                        z85Decode)

runIndex :: Config -> IO ()
runIndex cfg = maybeDetach cfg $ run $ do
    $(logDebug) "Initializing the sqlite connection pool"
    pool <- initDatabase cfg
    $(logDebug) "Initializing the HeaderTree"
    best <- runSql (initHeaderTree >> getBestBlock) (Right pool)
    $(logDebug) "Initializing the NodeState"
    let opts = L.defaultOptions { L.createIfMissing = True
                                , L.blockSize       = 256*1024
                                , L.cacheSize       = 256*1024*1024
                                , L.writeBufferSize = 1024*1024*1024
                                }
    db <- L.open "haskoin-index" opts
    state <- liftIO $ getNodeState cfg (Right pool) db best
    $(logDebug) "Initializing the LevelDB Index"
    runNodeT (withLevelDB initLevelDB) state
    $(logDebug) $ pack $ unwords
        [ "Starting indexer with", show $ length hosts, "hosts" ]
    as <- mapM async
        -- Spin up all the peers
        [ runNodeT (void $ mapConcurrently startPeer hosts) state
        -- Initial head sync and tickle processing
        , runNodeT startTickles state
        -- Blockchain download and address indexing
        , runNodeT (blockDownload 500) state
        -- Import solo transactions as they arrive from peers
        , runNodeT (txSource $$ processTx) state
        -- Respond to transaction GetData requests
        -- TODO ...
        -- , runNodeT (handleGetData $ (`runDBPool` pool) . getTx) state
        -- Run the ZMQ API server
        , runNodeT runApi state
        ]
    _ <- waitAnyCancel as
    return ()
  where
    run = runResourceT . runLogging
    runLogging = runStdoutLoggingT . filterLogger logFilter
    logFilter _ level = level >= configLogLevel cfg
    nodes = fromMaybe
        (error $ "BTC nodes for " ++ networkName ++ " not found")
        (pack networkName `H.lookup` configBTCNodes cfg)
    hosts = map (\x -> PeerHost (btcNodeHost x) (btcNodePort x)) nodes
    processTx = awaitForever $ \tx -> return () -- TODO

maybeDetach :: Config -> IO () -> IO ()
maybeDetach cfg action =
    if configDetach cfg then runDetached pidFile logFile action else action
  where
    pidFile = Just $ configPidFile cfg
    logFile = ToFile $ configLogFile cfg

initDatabase :: (MonadBaseControl IO m, MonadLoggerIO m)
             => Config -> m ConnectionPool
initDatabase cfg = do
    -- Create a database pool
    let dbCfg = fromMaybe
            (error $ "DB config settings for " ++ networkName ++ " not found")
            (pack networkName `H.lookup` configDatabase cfg)
    pool <- getDatabasePool dbCfg
    -- Initialize wallet database
    runSql (runMigration migrateHeaderTree) (Right pool)
    -- Return the semaphrone and the connection pool
    return pool

startTickles :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
startTickles = do
    $(logInfo) "Starting the initial header sync"
    headerSync
    $(logInfo) "Initial header sync complete"
    $(logDebug) "Starting the tickle processing thread"
    processTickles

broadcastTxs :: (MonadLoggerIO m, MonadBaseControl IO m)
             => [TxHash]
             -> NodeT m ()
broadcastTxs txids = do
    forM_ txids $ \tid -> $(logInfo) $ pack $ unwords
        [ "Transaction INV broadcast:", cs $ txHashToHex tid ]
    -- Broadcast an INV message for new transactions
    let msg = MInv $ Inv $ map (InvVector InvTx . getTxHash) txids
    atomicallyNodeT $ sendMessageAll msg

-- Run the main ZeroMQ loop
-- TODO: Support concurrent requests using DEALER socket when we can do
-- concurrent MySQL requests.
runApi :: ( MonadLoggerIO m
          , MonadBaseControl IO m
          )
       => NodeT m ()
runApi = liftBaseOpDiscard withContext $ \ctx -> do
    liftBaseOpDiscard (withSocket ctx Rep) $ \sock -> do
        setupCrypto ctx sock
        cfg <- asks sharedConfig
        liftIO $ bind sock $ configBind cfg
        forever $ do
            bs  <- liftIO $ receive sock
            res <- case decode $ BL.fromStrict bs of
                Just r  -> catchErrors $ dispatchRequest r
                Nothing -> return $ ResponseError IndexInvalidRequest
            liftIO $ send sock [] $ BL.toStrict $ encode res
  where
    setupCrypto :: (MonadLoggerIO m, MonadBaseControl IO m)
                => Context -> Socket a -> NodeT m ()
    setupCrypto ctx sock = do
        cfg <- asks sharedConfig
        let serverKeyM = configServerKey cfg
            clientKeyPubM = configClientKeyPub cfg
        when (isJust serverKeyM) $ liftIO $ do
            let k = fromJust serverKeyM
            setCurveServer True sock
            setCurveSecretKey TextFormat k sock
        when (isJust clientKeyPubM) $ do
            k <- z85Decode (fromJust clientKeyPubM)
            void $ async $ runZapAuth ctx k
    catchErrors m = catches m
        [ E.Handler $ \(ErrorCall err) -> do
            $(logError) $ pack err
            return $ ResponseError $ IndexServerError err
        , E.Handler $ \(SomeException exc) -> do
            $(logError) $ pack $ show exc
            return $ ResponseError $ IndexServerError $ show exc
        ]

runZapAuth :: ( MonadLoggerIO m
              , MonadBaseControl IO m
              )
           => Context -> ByteString -> m ()
runZapAuth ctx k = do
    $(logDebug) $ "Starting ØMQ authentication thread"
    liftBaseOpDiscard (withSocket ctx Rep) $ \zap -> do
        liftIO $ bind zap "inproc://zeromq.zap.01"
        forever $ do
            buffer <- liftIO $ receiveMulti zap
            let actionE =
                    case buffer of
                      v:q:_:_:_:m:p:_ -> do
                          when (v /= "1.0") $
                              Left (q, "500", "Version number not valid")
                          when (m /= "CURVE") $
                              Left (q, "400", "Mechanism not supported")
                          when (p /= k) $
                              Left (q, "400", "Invalid client public key")
                          return q
                      _ -> Left ("", "500", "Malformed request")
            case actionE of
              Right q -> do
                  $(logInfo) "Authenticated client successfully"
                  liftIO $ sendMulti zap $
                      "1.0" :| [q, "200", "OK", "client", ""]
              Left (q, c, m) -> do
                  $(logError) $ pack $ unwords
                      [ "Failed to authenticate client:" , cs c, cs m ]
                  liftIO $ sendMulti zap $
                      "1.0" :| [q, c, m, "", ""]

dispatchRequest :: ( MonadLoggerIO m
                   , MonadBaseControl IO m
                   )
                => IndexRequest -> NodeT m IndexResponse
dispatchRequest req = case req of
    GetNodeStatusR -> getNodeStatusR

