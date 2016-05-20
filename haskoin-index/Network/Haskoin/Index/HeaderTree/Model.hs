module Network.Haskoin.Index.HeaderTree.Model where

import           Data.Binary                            (Binary, get, put)
import           Data.Word                              (Word32)
import           Database.Persist.TH                    (mkMigrate, mkPersist,
                                                         persistLowerCase,
                                                         share, sqlSettings)
import           Network.Haskoin.Index.HeaderTree.Types

share [mkPersist sqlSettings, mkMigrate "migrateHeaderTree"] [persistLowerCase|
NodeBlock
    hash         ShortHash
    header       NodeHeader    maxlen=80
    work         Work
    height       BlockHeight
    chain        Word32
    UniqueHash   hash
    UniqueChain  chain height
    deriving     Show
    deriving     Eq
|]

instance Binary NodeBlock where
    put (NodeBlock sh (NodeHeader bh) w h c) =
        put sh >> put bh >> put w >> put h >> put c
    get = NodeBlock <$> get <*> (NodeHeader <$> get) <*> get <*> get <*> get

