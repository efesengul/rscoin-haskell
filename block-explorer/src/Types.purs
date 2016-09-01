module App.Types
       ( module RSCoin
       , module Color
       , Action (..)
       , SearchQuery (..)
       , init
       , State
       , queryToString
       ) where

import Prelude                     (show, class Eq)

import App.Routes                  (Path (NotFound))
import App.Connection              (Connection, Action) as C
import App.RSCoin                  as RSCoin
import App.RSCoin                  (Coin, Address,
                                    TransactionSummary (..),
                                    addressToString, CoinsMapSummary)
import Data.Color                  as Color
import Data.I18N                   (Language (..))

import Data.Maybe                  (Maybe (..))
import Data.Generic                (gEq)


data Action
    = PageView Path
    | SocketAction C.Action
    | SearchQueryChange String
    | SearchButton
    | DismissError
    | ColorToggle
    | LanguageSet Language
    | Nop

data SearchQuery
    = SQAddress Address
    | SQTransaction TransactionSummary

queryToString :: SearchQuery -> String
queryToString (SQAddress addr) = addressToString addr
queryToString (SQTransaction (TransactionSummary tId)) = show tId.txsId

instance eqSearchQeuery :: Eq SearchQuery where
    eq (SQAddress addr1) (SQAddress addr2) = gEq addr1 addr2
    -- TODO: use `eq tId.txId tId2.txId` here to optimize
    eq (SQTransaction tId1) (SQTransaction tId2) = gEq tId1 tId2
    eq _ _ = false

type State =
    { route            :: Path
    , socket           :: Maybe C.Connection
    , socketReady      :: Boolean
    , pendingActions   :: Array Action
    , queryInfo        :: Maybe SearchQuery
    , isAuthenticated  :: Boolean
    , searchQuery      :: String
    , balance          :: Maybe CoinsMapSummary
    , txNumber         :: Maybe Int
    , transactions     :: Array TransactionSummary
    , periodId         :: Int
    , error            :: Maybe String
    , colors           :: Boolean
    , language         :: Language
    }

init :: State
init =
    { route:            NotFound
    , socket:           Nothing
    , socketReady:      false
    , pendingActions:   []
    , queryInfo:        Nothing
    , isAuthenticated:  false
    , searchQuery:      ""
    , balance:          Nothing
    , txNumber:         Nothing
    , transactions:     []
    , periodId:         0
    , error:            Nothing
    , colors:           false
    , language:         English
    }
