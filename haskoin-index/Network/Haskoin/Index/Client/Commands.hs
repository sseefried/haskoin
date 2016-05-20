module Network.Haskoin.Index.Client.Commands
( cmdStart
, cmdStop
, cmdStatus
, cmdVersion
)
where

import           Control.Concurrent.Async.Lifted       (async, wait)
import           Control.Monad                         (forM_)
import qualified Control.Monad.Reader                  as R (ReaderT, ask, asks)
import           Control.Monad.Trans                   (liftIO)
import           Data.Aeson                            (FromJSON, ToJSON,
                                                        eitherDecode, encode)
import qualified Data.Aeson.Encode.Pretty              as JSON (Config (..),
                                                                defConfig,
                                                                encodePretty')
import           Data.List                             (intercalate)
import           Data.Maybe                            (fromMaybe, maybeToList)
import           Data.String.Conversions               (cs)
import qualified Data.Yaml                             as YAML (encode)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Index.Server
import           Network.Haskoin.Index.Server.Handlers
import           Network.Haskoin.Index.Settings
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Transaction
import           System.Posix.Daemon                   (killAndWait)
import           System.ZMQ4                           (KeyFormat (..),
                                                        Req (..), Socket,
                                                        SocketType, connect,
                                                        receive, send,
                                                        setCurvePublicKey,
                                                        setCurveSecretKey,
                                                        setCurveServerKey,
                                                        withContext, withSocket)

type Handler = R.ReaderT Config IO

-- hw start [config] [--detach]
cmdStart :: Handler ()
cmdStart = do
    cfg <- R.ask
    liftIO $ runIndex cfg
    liftIO $ putStrLn "Indexer started"

-- hw stop [config]
cmdStop :: Handler ()
cmdStop = R.ask >>= \cfg -> liftIO $ do
    killAndWait $ configPidFile cfg
    putStrLn "Indexer stopped"

cmdStatus :: Handler ()
cmdStatus = handleResponse =<< sendZmq GetNodeStatusR

cmdVersion :: Handler ()
cmdVersion = liftIO $ do
    putStrLn $ unwords [ "network   :", cs networkName ]
    putStrLn $ unwords [ "user-agent:", cs haskoinUserAgent ]

{- Helpers -}

handleResponse
    :: Either String IndexResponse
    -> Handler ()
handleResponse resE = case resE of
    Right res -> case res of
        ResponseNodeStatus ns -> formatOutput ns (unlines . printNodeStatus)
        ResponseError err -> error $ case err of
            IndexInvalidRequest -> "Invalid JSON request"
            IndexServerError m -> unwords [ "Server error:", m ]
    Left err -> error err

formatOutput :: (ToJSON a, FromJSON a) => a -> (a -> String) -> Handler ()
formatOutput a handle = R.asks configFormat >>= \f -> liftIO $ case f of
    OutputJSON   -> formatStr $ cs $
        JSON.encodePretty' JSON.defConfig{ JSON.confIndent = 2 } a
    OutputYAML   -> formatStr $ cs $ YAML.encode a
    OutputNormal -> formatStr $ handle a

sendZmq :: IndexRequest -> Handler (Either String IndexResponse)
sendZmq req = do
    cfg <- R.ask
    a <- async $ liftIO $ withContext $ \ctx ->
        withSocket ctx Req $ \sock -> do
            setupAuth cfg sock
            connect sock (configBind cfg)
            send sock [] (cs $ encode req)
            eitherDecode . cs <$> receive sock
    wait a

setupAuth :: (SocketType t)
          => Config
          -> Socket t
          -> IO ()
setupAuth cfg sock = do
    let clientKeyM    = configClientKey    cfg
        clientKeyPubM = configClientKeyPub cfg
        serverKeyPubM = configServerKeyPub cfg
    forM_ clientKeyM $ \clientKey -> do
        let serverKeyPub = fromMaybe
              (error "Server public key not provided")
              serverKeyPubM
            clientKeyPub = fromMaybe
              (error "Client public key not provided")
              clientKeyPubM
        setCurveServerKey TextFormat serverKeyPub sock
        setCurvePublicKey TextFormat clientKeyPub sock
        setCurveSecretKey TextFormat clientKey sock

formatStr :: String -> IO ()
formatStr str = forM_ (lines str) putStrLn

printNodeStatus :: NodeStatus -> [String]
printNodeStatus NodeStatus{..} =
    [ "Network Height    : " ++ show nodeStatusNetworkHeight
    , "Best Header       : " ++ cs (blockHashToHex nodeStatusBestHeader)
    , "Best Header Height: " ++ show nodeStatusBestHeaderHeight
    , "Best Block        : " ++ cs (blockHashToHex nodeStatusBestBlock)
    , "Best Block Height : " ++ show nodeStatusBestBlockHeight
    ] ++
    [ "Header Peer       : " ++ show h
    | h <- maybeToList nodeStatusHeaderPeer
    ] ++
    [ "Pending Headers   : " ++ show nodeStatusHaveHeaders ] ++
    [ "Pending Tickles   : " ++ show nodeStatusHaveTickles ] ++
    [ "Pending Txs       : " ++ show nodeStatusHaveTxs ] ++
    [ "Pending GetData   : " ++ show (map txHashToHex nodeStatusGetData) ] ++
    [ "Synced Mempool    : " ++ show nodeStatusMempool ] ++
    [ "HeaderSync Lock   : " ++ show nodeStatusSyncLock ] ++
    [ "LevelDB Lock      : " ++ show nodeStatusLevelLock ] ++
    [ "Peers: " ] ++
    intercalate ["-"] (map printPeerStatus nodeStatusPeers)

printPeerStatus :: PeerStatus -> [String]
printPeerStatus PeerStatus{..} =
    [ "  Peer Id  : " ++ show peerStatusPeerId
    , "  Peer Host: " ++ peerHostString peerStatusHost
    , "  Connected: " ++ if peerStatusConnected then "yes" else "no"
    , "  Height   : " ++ show peerStatusHeight
    ] ++
    [ "  Protocol : " ++ show p | p <- maybeToList peerStatusProtocol
    ] ++
    [ "  UserAgent: " ++ ua | ua <- maybeToList peerStatusUserAgent
    ] ++
    [ "  Blocks   : " ++ show peerStatusHaveBlocks ] ++
    [ "  Messages : " ++ show peerStatusHaveMessage ] ++
    [ "  Nonces   : " ++ show peerStatusPingNonces ] ++
    [ "  Reconnect: " ++ show t | t <- maybeToList peerStatusReconnectTimer ]

