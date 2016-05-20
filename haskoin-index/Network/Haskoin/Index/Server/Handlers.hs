module Network.Haskoin.Index.Server.Handlers where

import           Control.Concurrent.STM           (STM, isEmptyTMVar, readTVar)
import           Control.Concurrent.STM.Lock      (locked)
import           Control.Concurrent.STM.TBMChan   (isEmptyTBMChan)
import           Control.Monad                    (mzero)
import           Control.Monad.Logger             (MonadLoggerIO, logInfo)
import           Control.Monad.Reader             (ask)
import           Control.Monad.Trans              (MonadIO, lift)
import           Control.Monad.Trans.Control      (MonadBaseControl)
import           Data.Aeson                       (FromJSON, ToJSON, object,
                                                   parseJSON, toJSON,
                                                   withObject, (.:), (.=))
import           Data.Aeson.TH                    (deriveJSON)
import           Data.Aeson.Types                 (Options (..),
                                                   SumEncoding (..),
                                                   defaultOptions,
                                                   defaultTaggedObject)
import qualified Data.ByteString.Char8            as C (unpack)
import           Data.Char                        (toLower)
import qualified Data.Map.Strict                  as M (keys)
import           Data.Text                        (Text, pack)
import           Data.Unique                      (hashUnique)
import           Data.Word                        (Word32)
import           Network.Haskoin.Block
import           Network.Haskoin.Index.BlockChain
import           Network.Haskoin.Index.HeaderTree
import           Network.Haskoin.Index.Peer
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util

{- Node Status -}

data PeerStatus = PeerStatus
    -- Regular fields
    { peerStatusPeerId         :: !Int
    , peerStatusHost           :: !PeerHost
    , peerStatusConnected      :: !Bool
    , peerStatusHeight         :: !BlockHeight
    , peerStatusProtocol       :: !(Maybe Word32)
    , peerStatusUserAgent      :: !(Maybe String)
    -- Debug fields
    , peerStatusHaveMessage    :: !Bool
    , peerStatusHaveBlocks     :: !Bool
    , peerStatusPingNonces     :: ![PingNonce]
    , peerStatusReconnectTimer :: !(Maybe Int)
    }

$(deriveJSON (dropFieldLabel 10) ''PeerStatus)

data NodeStatus = NodeStatus
    -- Regular fields
    { nodeStatusPeers            :: ![PeerStatus]
    , nodeStatusNetworkHeight    :: !BlockHeight
    , nodeStatusBestHeader       :: !BlockHash
    , nodeStatusBestHeaderHeight :: !BlockHeight
    , nodeStatusBestBlock        :: !BlockHash
    , nodeStatusBestBlockHeight  :: !BlockHeight
    -- Debug fields
    , nodeStatusHeaderPeer       :: !(Maybe Int)
    , nodeStatusHaveHeaders      :: !Bool
    , nodeStatusHaveTickles      :: !Bool
    , nodeStatusHaveTxs          :: !Bool
    , nodeStatusGetData          :: ![TxHash]
    , nodeStatusMempool          :: !Bool
    , nodeStatusSyncLock         :: !Bool
    , nodeStatusLevelLock        :: !Bool
    }

$(deriveJSON (dropFieldLabel 10) ''NodeStatus)


{- Request/Response types -}

data IndexRequest
    = GetNodeStatusR

$(deriveJSON
    defaultOptions
        { constructorTagModifier = map toLower . init
        , sumEncoding = defaultTaggedObject
            { tagFieldName      = "method"
            , contentsFieldName = "params"
            }
        }
    ''IndexRequest
 )

data IndexError
    = IndexInvalidRequest
    | IndexServerError !String

instance ToJSON IndexError where
    toJSON err = case err of
        IndexInvalidRequest -> object
            [ "code"    .= (-32600 :: Int)
            , "message" .= ("Invalid JSON request" :: String)
            ]
        IndexServerError m -> object
            [ "code"    .= (-32000 :: Int)
            , "message" .= m
            ]

instance FromJSON IndexError where
    parseJSON = withObject "IndexError" $ \o -> do
        code <- o .: "code"
        msg  <- o .: "message"
        case (code :: Int) of
            (-32600) -> return IndexInvalidRequest
            (-32000) -> return $ IndexServerError msg
            _        -> mzero

data IndexResponse
    = ResponseNodeStatus !NodeStatus
    | ResponseError !IndexError

$(deriveJSON
    defaultOptions
        { constructorTagModifier = map toLower . drop 8
        , sumEncoding = defaultTaggedObject
            { tagFieldName      = "type"
            , contentsFieldName = "data"
            }
        }
    ''IndexResponse
 )

{- Server Handlers -}

getNodeStatusR :: (MonadLoggerIO m, MonadBaseControl IO m)
               => NodeT m IndexResponse
getNodeStatusR = do
    $(logInfo) $ format "GetNodeStatusR"
    status <- nodeStatus
    return $ ResponseNodeStatus status

nodeStatus :: (MonadIO m, MonadBaseControl IO m) => NodeT m NodeStatus
nodeStatus = do
    SharedNodeState{..} <- ask
    best   <- withLevelDB bestIndexedBlock
    header <- runSqlNodeT getBestBlock
    let nodeStatusBestBlock        = nodeHash best
        nodeStatusBestBlockHeight  = nodeBlockHeight best
        nodeStatusBestHeader       = nodeHash header
        nodeStatusBestHeaderHeight = nodeBlockHeight header
    atomicallyNodeT $ do
        nodeStatusPeers <- mapM peerStatus =<< getPeers
        lift $ do
            nodeStatusHeaderPeer <-
                fmap hashUnique <$> readTVar sharedHeaderPeer
            nodeStatusNetworkHeight <- readTVar sharedNetworkHeight
            nodeStatusHaveHeaders <- not <$> isEmptyTMVar sharedHeaders
            nodeStatusHaveTickles <- not <$> isEmptyTBMChan sharedTickleChan
            nodeStatusHaveTxs <- not <$> isEmptyTBMChan sharedTxChan
            nodeStatusGetData <- M.keys <$> readTVar sharedTxGetData
            nodeStatusMempool <- readTVar sharedMempool
            nodeStatusSyncLock <- locked sharedSyncLock
            nodeStatusLevelLock <- locked sharedSyncLock
            return NodeStatus{..}

peerStatus :: (PeerId, PeerSession) -> NodeT STM PeerStatus
peerStatus (pid, PeerSession{..}) = do
    hostM <- getHostSession peerSessionHost
    let peerStatusPeerId    = hashUnique pid
        peerStatusHost      = peerSessionHost
        peerStatusConnected = peerSessionConnected
        peerStatusHeight    = peerSessionHeight
        peerStatusProtocol  = version <$> peerSessionVersion
        peerStatusUserAgent =
            C.unpack . getVarString . userAgent <$> peerSessionVersion
        peerStatusReconnectTimer = peerHostSessionReconnect <$> hostM
    lift $ do
        peerStatusHaveBlocks  <- not <$> isEmptyTBMChan peerSessionBlockChan
        peerStatusHaveMessage <- not <$> isEmptyTBMChan peerSessionChan
        peerStatusPingNonces  <- readTVar peerSessionPings
        return PeerStatus{..}

{- Helpers -}

format :: String -> Text
format str = pack $ "[ZeroMQ] " ++ str

