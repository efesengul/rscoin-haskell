{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types          #-}
-- | This module provides high-abstraction functions to exchange data
-- within user/mintette/bank.

module RSCoin.Core.Communication
       ( CommunicationError (..)
       , getBlockchainHeight
       , getBlockByHeight
       , getGenesisBlock
       , checkNotDoubleSpent
       , commitTx
       , sendPeriodFinished
       , announceNewPeriod
       , getOwnersByAddrid
       , getOwnersByTx
       , P.unCps
       , getBlocks
       , getMintettes
       , getLogs
       , getMintetteUtxo
       , getMintetteBlocks
       , getMintetteLogs
       ) where

import           Control.Exception          (Exception, throwIO)
import           Control.Monad.Catch        (catch)
import           Control.Monad.Trans        (MonadIO, liftIO)
import           Data.Monoid                ((<>))
import           Data.MessagePack           (MessagePack)
import           Data.Text                  (Text, pack)
import           Data.Text.Buildable        (Buildable (build))
import           Data.Tuple.Select          (sel1)
import           Data.Typeable              (Typeable)
import qualified Network.MessagePack.Client as MP (RpcError (..))

import           Safe                      (atMay)
import           Serokell.Util.Text        (format', formatSingle', show',
                                            mapBuilder, listBuilderJSONIndent,
                                            pairBuilder)

import           RSCoin.Core.Crypto         (Signature, hash)
import           RSCoin.Core.Owners         (owners)
import           RSCoin.Core.Primitives     (AddrId, Transaction, TransactionId)
import qualified RSCoin.Core.Protocol       as P
import           RSCoin.Core.Logging        (logInfo, logWarning, logError)
import           RSCoin.Core.Types          (CheckConfirmation,
                                             CheckConfirmations,
                                             CommitConfirmation, HBlock,
                                             Mintette, MintetteId,
                                             NewPeriodData, PeriodId,
                                             PeriodResult, Mintettes,
                                             ActionLog, Utxo, LBlock)
import           RSCoin.Test                (WorkMode)

-- | Errors which may happen during remote call.
data CommunicationError
    = ProtocolError Text  -- ^ Message was encoded incorrectly.
    | MethodError Text    -- ^ Error occured during method execution.
    deriving (Show, Typeable)

instance Exception CommunicationError

instance Buildable CommunicationError where
    build (ProtocolError t) = "internal error: " <> build t
    build (MethodError t) = "method error: " <> build t

rpcErrorHandler :: MonadIO m => MP.RpcError -> m a 
rpcErrorHandler = liftIO . log' . fromError
  where
    log' (e :: CommunicationError) = do
        logError $ show' e
        throwIO e
    fromError (MP.ProtocolError s) = ProtocolError $ pack s
    fromError (MP.ResultTypeError s) = ProtocolError $ pack s
    fromError (MP.ServerError obj) = MethodError $ pack $ show obj

callBank :: (WorkMode m, MessagePack a) => P.Client a -> m a
callBank cl = P.callBank cl `catch` rpcErrorHandler

callMintette :: (WorkMode m, MessagePack a) => Mintette -> P.Client a -> m a
callMintette m cl = P.callMintette m cl `catch` rpcErrorHandler

withResult :: WorkMode m => IO () -> (a -> IO ()) -> m a -> m a
withResult before after action = do
    liftIO before 
    a <- action 
    liftIO $ after a     
    return a

-- | Retrieves blockchainHeight from the server
getBlockchainHeight :: WorkMode m => m PeriodId
getBlockchainHeight =
    withResult
        (logInfo "Getting blockchain height")
        (logInfo . formatSingle' "Blockchain height is {}")
        $ callBank $ P.call (P.RSCBank P.GetBlockchainHeight)

-- | Given the height/perioud id, retreives block if it's present
getBlockByHeight :: WorkMode m => PeriodId -> m HBlock
getBlockByHeight pId = do
    logInfo $ formatSingle' "Getting block with height {}" pId
    res <- callBank $ P.call (P.RSCBank P.GetHBlock) pId
    liftIO $ either onError onSuccess res
  where
    onError e = do
        logWarning $
            format' "Getting block with height {} failed with: {}" (pId, e)
        throwIO $ MethodError e
    onSuccess res = do
        logInfo $
            format' "Successfully got block with height {}: {}" (pId, res)
        return res

getGenesisBlock :: WorkMode m => m HBlock
getGenesisBlock = do
    liftIO $ logInfo "Getting genesis block"
    block <- getBlockByHeight 0
    liftIO $ logInfo "Successfully got genesis block"
    return block

getOwnersByHash :: WorkMode m => TransactionId -> m [(Mintette, MintetteId)]
getOwnersByHash tId =
    withResult
        (logInfo $ formatSingle' "Getting owners by transaction id {}" tId)
        (logInfo . format' "Successfully got owners by hash {}: {}" . (tId,) . mapBuilder)
        $ toOwners <$> (callBank $ P.call $ P.RSCBank P.GetMintettes)
  where
    toOwners mts =
        map
            (\i -> (mts !! i, i)) $
        owners mts tId

-- | Gets owners from Transaction
getOwnersByTx :: WorkMode m => Transaction -> m [(Mintette, MintetteId)]
getOwnersByTx tx =
    withResult
        (logInfo $ formatSingle' "Getting owners by transaction {}" tx)
        (const $ logInfo "Successfully got owners by transaction")
        $ getOwnersByHash $ hash tx

-- | Gets owners from Addrid
getOwnersByAddrid :: WorkMode m => AddrId -> m [(Mintette, MintetteId)]
getOwnersByAddrid aId =
    withResult
        (logInfo $ formatSingle' "Getting owners by addrid {}" aId)
        (const $ logInfo "Successfully got owners by addrid")
        $ getOwnersByHash $ sel1 aId

checkNotDoubleSpent
    :: WorkMode m 
    => Mintette
    -> Transaction
    -> AddrId
    -> Signature
    -> m (Either Text CheckConfirmation)
checkNotDoubleSpent m tx a s =
    withResult
        infoMessage
        (either onError onSuccess)
        $ callMintette m $ P.call (P.RSCMintette P.CheckTx) tx a s
  where
    infoMessage =
        logInfo $
            format' "Checking addrid ({}) from transaction: {}" (a, tx)
    onError e =
        logWarning $
        formatSingle' "Checking double spending failed with: {}" e
    onSuccess res = do
        logInfo $
            format' "Confirmed addrid ({}) from transaction: {}" (a, tx)
        logInfo $ formatSingle' "Confirmation: {}" res

commitTx
    :: WorkMode m
    => Mintette
    -> Transaction
    -> PeriodId
    -> CheckConfirmations
    -> m (Maybe CommitConfirmation)
commitTx m tx pId cc = do
    logInfo $
        format' "Commit transaction {}, provided periodId is {}" (tx, pId)
    res <- callMintette m $ P.call (P.RSCMintette P.CommitTx) tx pId cc
    liftIO $ either onError onSuccess res
  where
    onError (e :: Text) = do
        logWarning $
            formatSingle' "CommitTx failed: {}" e
        return Nothing
    onSuccess res = do
        logInfo $
            formatSingle' "Successfully committed transaction {}" tx
        return $ Just res

sendPeriodFinished :: WorkMode m => Mintette -> PeriodId -> m PeriodResult
sendPeriodFinished mintette pId =
    withResult
        infoMessage
        successMessage
        $ callMintette mintette $ P.call (P.RSCMintette P.PeriodFinished) pId
  where
    infoMessage =
        logInfo $
            format' "Send period {} finished to mintette {}" (pId, mintette)
    successMessage (_,blks,lgs) =
        logInfo $
            format' "Received period result from mintette {}: \n Blocks: {}\n Logs: {}\n"
            (mintette, listBuilderJSONIndent 2 blks, lgs)

announceNewPeriod :: WorkMode m => Mintette -> NewPeriodData -> m ()
announceNewPeriod mintette npd = do
    logInfo $
        format' "Announce new period to mintette {}, new period data {}" (mintette, npd)
    callMintette
        mintette
        (P.call (P.RSCMintette P.AnnounceNewPeriod) npd)

-- Dumping Bank state

getBlocks :: WorkMode m => PeriodId -> PeriodId -> m [HBlock]
getBlocks from to =
    withResult
        infoMessage
        successMessage
        $ callBank $ P.call (P.RSCDump P.GetHBlocks) from to
  where
    infoMessage =
        logInfo $
            format' "Getting higher-level blocks between {} and {}"
            (from, to)
    successMessage res =
        logInfo $
            format' "Got higher-level blocks between {} {}: {}"
            (from, to, listBuilderJSONIndent 2 res)

getMintettes :: WorkMode m => m Mintettes
getMintettes =
    withResult
        (logInfo "Getting list of mintettes")
        (logInfo . formatSingle' "Successfully got list of mintettes {}")
        $ callBank $ P.call (P.RSCBank P.GetMintettes)

getLogs :: WorkMode m => MintetteId -> Int -> Int -> m (Maybe ActionLog)
getLogs m from to = do
    logInfo $
        format' "Getting action logs of mintette {} with range of entries {} to {}" (m, from, to)
    res <- callBank $ P.call (P.RSCDump P.GetLogs) m from to
    liftIO $ either onError onSuccess res
  where
    onError (e :: Text) = do
        logWarning e
        return Nothing
    onSuccess aLog = do
        logInfo $
            format'
                "Action logs of mintette {} (range {} - {}): {}"
                (m, from, to, aLog)
        return $ Just aLog

-- Dumping Mintette state

getMintetteUtxo :: WorkMode m => MintetteId -> m Utxo
getMintetteUtxo mId = do
    ms <- getMintettes
    maybe onNothing onJust $ ms `atMay` mId
  where
    onNothing = liftIO $ do
        let e = formatSingle' "Mintette with this index {} doesn't exist" mId
        logWarning e
        throwIO $ MethodError e
    onJust mintette =
        withResult
            (logInfo "Getting utxo")
            (logInfo . formatSingle' "Corrent utxo is: {}")
            (callMintette mintette $ P.call (P.RSCDump P.GetMintetteUtxo))

getMintetteBlocks :: WorkMode m => MintetteId -> PeriodId -> m (Maybe [LBlock])
getMintetteBlocks mId pId = do
    ms <- getMintettes
    maybe onNothing onJust $ ms `atMay` mId
  where
    onNothing = liftIO $ do
        let e = formatSingle' "Mintette with this index {} doesn't exist" mId
        logWarning e
        throwIO $ MethodError e
    onJust mintette = do
        logInfo $
            format' "Getting blocks of mintette {} with period id {}" (mId, pId)
        res <- callMintette mintette $ P.call (P.RSCDump P.GetMintetteBlocks) pId
        liftIO $ either onError onSuccess res
      where
        onError (e :: Text) = do
            logWarning e
            return Nothing
        onSuccess res = do
            logInfo $
                format'
                    "Successfully got blocks for period id {}: {}"
                    (pId, listBuilderJSONIndent 2 res)
            return $ Just res

-- TODO: code duplication as getMintetteBlocks, refactor!
getMintetteLogs :: WorkMode m => MintetteId -> PeriodId -> m (Maybe ActionLog)
getMintetteLogs mId pId = do
    ms <- getMintettes
    maybe onNothing onJust $ ms `atMay` mId
  where
    onNothing = liftIO $ do
        let e = formatSingle' "Mintette with this index {} doesn't exist" mId
        logWarning e
        throwIO $ MethodError e
    onJust mintette = do
        logInfo $
            format' "Getting logs of mintette {} with period id {}" (mId, pId)
        res <- callMintette mintette $ P.call (P.RSCDump P.GetMintetteLogs) pId
        liftIO $ either onError onSuccess res
      where
        onError (e :: Text) = do
            logWarning e
            return Nothing
        onSuccess res = do
            logInfo $
                format'
                    "Successfully got logs for period id {}: {}"
                    (pId, listBuilderJSONIndent 2 $ map pairBuilder res)
            return $ Just res
