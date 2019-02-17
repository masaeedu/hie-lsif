{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NamedFieldPuns #-}
module WriteJSON where

import GHC
import OccName
import HieTypes hiding (Identifier)
import Name


import qualified Data.Map as M
import qualified Data.Set as S

import Control.Monad
import Control.Monad.State.Strict
import Control.Monad.Writer.Strict
import NameEnv

import Data.Aeson
import Data.Aeson.Types

import Data.Text(Text)

import LoadHIE

import qualified Data.ByteString.Lazy.Char8 as L

type M a = WriterT [Value] (StateT MS IO) a

type Identifier = (OccName, ModuleName)

type ResultSetMap = NameEnv Int
type ReferenceResultMap = NameEnv Int
type RangeMap = M.Map RealSrcSpan Int
type ModuleMap = M.Map Module Int

data MS = MS { counter :: !Int
             , resultSetMap :: ResultSetMap
             , referenceResultMap :: ReferenceResultMap
             , rangeMap :: RangeMap
             , exports :: [(Name, Int)]
             , importMap :: ModuleMap }

addExport :: Name -> Int -> M ()
addExport n rid = modify (\st -> st { exports = (n, rid) : exports st })


prefix :: String
prefix = "file://"

mkDocumentNode :: FilePath -> FilePath -> M Int
mkDocumentNode root fp =
  let val = [ "label" .= ("document" :: Text)
            , "uri" .= (prefix ++ root ++ fp)
            , "languageId" .= ("haskell" :: Text)
            , "type" .= ("vertex" :: Text) ]
  in uniqueNode val

{-
addImportedReference :: Int -> Module -> Name -> M ()
addImportedReference use_range m n = do
  im_r <- addImportedModule m
  eii <- mkExternalImportItem n use_range
  mkItemEdge im_r eii
  return ()
  -}



{-
addImportedModule :: Module -> M Int
addImportedModule m = do
  ma <- gets importMap
  case M.lookup m ma of
    Just i  -> return i
    Nothing -> do
      liftIO $ print (moduleNameString (moduleName m))
      i <- mkDocumentNode "/home/matt/hie-lsif/test/simple-tests/B.js"
      ei <- mkExternalImportResult
      mkImportsEdge i ei

      modify (\s -> s { importMap = M.insert m ei ma } )
      return i
      -}

mkDocument :: Int -> FilePath -> FilePath -> M Int
mkDocument proj_node root fp = do
  doc <- mkDocumentNode root fp
  mkContainsEdge proj_node doc
  return doc


generateJSON :: FilePath -> ModRefs -> M ()
generateJSON root m = do
  proj_node <- mkProjectVertex Nothing
  rs <- mapM (\(fp, ref_mod, r) -> (, ref_mod, r) <$> mkDocument proj_node root fp ) m
  mapM_ do_one_file rs

  --emitExports dn
  where
    do_one_file (dn, ref_mod, r) = mapM_ (mkReferences dn ref_mod) r

emitExports :: Int -> M ()
emitExports dn = do
  es <- gets exports
  i <- mkExportResult es
  void $ mkExportsEdge dn i


-- Decide whether a reference is a bind or not.
getBind :: S.Set ContextInfo -> Maybe ContextInfo
getBind s = msum $ map go (S.toList s)
  where
    go c = case c of
             ValBind {} -> Just c
             PatternBind {} -> Just c
             _ -> Nothing


mkReferences :: Int -> Module -> Ref -> M ()
mkReferences dn _ (ast, Right ref_id, id_details)
  | Just {} <- getBind (identInfo id_details) = do
    -- Definition
    let s = nodeSpan ast
    rs <- mkResultSet ref_id
    def_range <- mkRangeIn dn s
    def_result <- mkDefinitionResult def_range
    _ <- mkDefinitionEdge rs def_result

    -- Reference
    rr <- mkReferenceResult ref_id
    mkRefersTo def_range rs
    mkDefEdge rr def_range
    mkReferencesEdge rs rr

    -- Export
    --addExport id def_range


    liftIO $ print (s, occNameString (getOccName ref_id), (identInfo id_details))
  | Use `S.member` identInfo id_details = do
    let s = nodeSpan ast
    use_range <- mkRangeIn dn s
    rs <- mkResultSet ref_id
    rr <- mkReferenceResult ref_id
    mkRefersTo use_range rs
    mkRefEdge rr use_range
    mkHover use_range ast

{-
    case nameModule_maybe id of
      Just m | not (isGoodSrcSpan (nameSrcSpan id))  -> void $ addImportedReference use_range m id
      _ -> return ()
      -}
    liftIO $ print (s, nameStableString ref_id, nameSrcSpan ref_id, occNameString (getOccName ref_id), (identInfo id_details))
  | otherwise =
    liftIO $ print (nodeSpan ast, occNameString (getOccName ref_id), (identInfo id_details))
mkReferences _ _ (s, Left mn, _)  =
  liftIO $ print (nodeSpan s , moduleNameString mn)




initialState :: MS
initialState = MS 1 emptyNameEnv emptyNameEnv M.empty [] M.empty

writeJSON :: FilePath -> ModRefs -> IO ()
writeJSON root r = do
  ref <- flip evalStateT initialState (execWriterT (generateJSON root r))
  let res = encode ref
  L.writeFile "test.json" res



-- JSON generation functions
--

nameToKey :: Name -> String
nameToKey = getOccString

-- For a given identifier, make the ResultSet node and add the mapping
-- from that identifier to its result set
mkResultSet :: Name -> M Int
mkResultSet n = do
  m <- gets resultSetMap
  case lookupNameEnv m n of
    Just i  -> return i
    Nothing -> do
      i <- mkResultSetWithKey n
      modify (\s -> s { resultSetMap = extendNameEnv m n i } )
      return i


mkResultSetWithKey :: Name -> M Int
mkResultSetWithKey n =
  "resultSet" `vWith` ["key" .= nameToKey n]


vWith :: Text -> [Pair] -> M Int
vWith l as = uniqueNode $ as ++  ["type" .= ("vertex" :: Text), "label" .= l ]

vertex :: Text -> M Int
vertex t = t `vWith` []


mkProjectVertex :: Maybe FilePath -> M Int
mkProjectVertex mcabal_file =
  "project" `vWith` (["projectFile" .= ("file://" ++ fn) | Just fn <- [mcabal_file]]
                    ++ ["language" .= ("haskell" :: Text)])


mkHover :: Int -> HieAST PrintedType -> M ()
mkHover range_id node =
  case mkHoverContents node of
    Nothing -> return ()
    Just c  -> do
      hr_id <- mkHoverResult c
      mkHoverEdge range_id hr_id



mkHoverResult :: Value -> M Int
mkHoverResult c =
  let result = "result" .= (object [ "contents" .= c ])
  in "hoverResult" `vWith` [result]

mkHoverContents :: HieAST PrintedType -> Maybe Value
mkHoverContents Node{nodeInfo} =
  case nodeType nodeInfo of
    [] -> Nothing
    (x:_) -> Just (object ["language" .= ("haskell" :: Text) , "value" .= x])

mkExternalImportResult :: M Int
mkExternalImportResult = vertex "externalImportResult"


mkExternalImportItem :: Name -> Int -> M Int
mkExternalImportItem n rid =
  "externalImportItem" `vWith` mkExpImpPairs n rid


mkExportResult :: [(Name, Int)] -> M Int
mkExportResult es =
  "exportResult" `vWith` ["result" .= (map (uncurry mkExportItem) es)]


mkExpImpPairs :: Name -> Int -> [Pair]
mkExpImpPairs name rid = [ "moniker" .= occNameString (getOccName name)
                         , "rangeIds" .= [rid] ]

mkExportItem :: Name -> Int -> Value
mkExportItem n rid = object (mkExpImpPairs n rid)

-- There are not higher equalities between edges.
mkEdgeWithProp :: Maybe Text -> Int -> Int -> Text -> M ()
mkEdgeWithProp mp from to l =
  void . uniqueNode $
    [ "type" .= ("edge" :: Text)
    , "label" .= l
    , "outV" .= from
    , "inV"  .= to ] ++ ["property" .= p | Just p <- [mp] ]

mkEdge :: Int -> Int -> Text -> M ()
mkEdge = mkEdgeWithProp Nothing

mkSpan :: Int -> Int -> Value
mkSpan l c = object ["line" .= l, "character" .= c]

mkRefersTo, mkContainsEdge, mkRefEdge, mkDefEdge, mkExportsEdge
  , mkDefinitionEdge, mkReferencesEdge, mkItemEdge
  , mkImportsEdge, mkHoverEdge :: Int -> Int -> M ()
mkRefersTo from to = mkEdge from to "refersTo"

mkExportsEdge from to = mkEdge from to "exports"

mkDefEdge from to = mkEdgeWithProp (Just "definition") from to "item"
mkRefEdge from to = mkEdgeWithProp (Just "reference")  from to "item"


mkContainsEdge from to = mkEdge from to "contains"

mkDefinitionEdge from to = mkEdge from to "textDocument/definition"
mkReferencesEdge from to = mkEdge from to "textDocument/references"
mkItemEdge from to = mkEdge from to "item"
mkImportsEdge from to = mkEdge from to "imports"

mkHoverEdge from to = mkEdge from to "textDocument/hover"

mkDefinitionResult :: ToJSON v => v -> M Int
mkDefinitionResult r =
 "definitionResult" `vWith` ["result" .= r]

mkReferenceResult :: Name -> M Int
mkReferenceResult n = do
  m <- gets referenceResultMap
  case lookupNameEnv m n of
    Just i  -> return i
    Nothing -> do
      i <- vertex "referenceResult"
      modify (\s -> s { referenceResultMap = extendNameEnv m n i } )
      return i


-- LSIF indexes from 0 rather than 1
mkRange :: Span -> M Int
mkRange s = do
  m <- gets rangeMap
  case M.lookup s m of
    Just i -> return i
    Nothing -> do
      i <- "range" `vWith`
            ["start" .= (mkSpan ls cs), "end" .= (mkSpan le ce)]
      modify (\st -> st { rangeMap = M.insert s i m } )
      return i

  where
    ls = srcSpanStartLine s - 1
    cs = srcSpanStartCol s - 1
    le = srcSpanEndLine s - 1
    ce = srcSpanEndCol s - 1

-- | Make a range and put bind it to the document
mkRangeIn :: Int -> Span -> M Int
mkRangeIn doc s = do
  v <- mkRange s
  void $ mkContainsEdge doc v
  return v


getId :: M Int
getId = do
  s <- gets counter
  modify (\st -> st { counter = s + 1 })
  return s

-- Tag a document with a unique ID
uniqueNode :: [Pair] -> M Int
uniqueNode o = do
  val <- getId
  tellOne (object ("id" .= val : o))
  return val

tellOne :: MonadWriter [a] m => a -> m ()
tellOne x = tell [x]
