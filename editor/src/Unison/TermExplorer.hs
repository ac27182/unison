{-# Language RecordWildCards #-}
{-# Language OverloadedStrings #-}
{-# Language ScopedTypeVariables #-}

module Unison.TermExplorer where

import Control.Monad
import Data.Either
import Data.List
import Data.Map (Map)
import Data.Maybe
import Data.Semigroup
import Data.Text (Text)
import Reflex.Dom
import Unison.Metadata (Metadata)
import Unison.Node (Node,SearchResults,LocalInfo)
import Unison.Node (SearchResults)
import Unison.Node.MemNode (V)
import Unison.Paths (Target, Path)
import Unison.Reference (Reference)
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import Unison.Type (Type)
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Unison.Dimensions as Dimensions
import qualified Unison.Doc as Doc
import qualified Unison.DocView as DocView
import qualified Unison.Explorer as Explorer
import qualified Unison.LiteralParser as LiteralParser
import qualified Unison.Metadata as Metadata
import qualified Unison.Node as Node
import qualified Unison.Parser as Parser
import qualified Unison.Paths as Paths
import qualified Unison.Term as Term
import qualified Unison.Typechecker as Typechecker
import qualified Unison.Var as Var
import qualified Unison.View as View
import qualified Unison.Views as Views

data S =
  S { metadata :: Map Reference (Metadata V Reference)
    , lastResults :: Maybe (SearchResults V Reference (Term V))
    , overallTerm :: Target V
    , path :: Path -- path into `overallTerm`
    , id :: Int }

instance Semigroup S where
  (S md1 r1 t1 p1 id1) <> (S md2 r2 t2 p2 id2) =
    S (Map.unionWith const md2 md1)
      (if id2 > id1 then r2 else r1)
      (if id2 > id1 then t2 else t1)
      (if id2 > id1 then p2 else p1)
      (id1 `max` id2)

type Advance = Bool

data Action
  = Replace Path (Term V)
  | Step Path
  | Eval Path

make :: forall t m . (MonadWidget t m, Reflex t)
     => Event t Int
     -> Event t (LocalInfo (Term V) (Type V))
     -> Dynamic t S
     -> m (Dynamic t S, Event t (Maybe (Action,Advance)))
make keydown localInfo s =
  let
    firstName (Metadata.Names (n:_)) = n
    lookupSymbol mds ref = maybe (Views.defaultSymbol ref) (firstName . Metadata.names) (Map.lookup ref mds)
    lookupName mds ref = Var.name (lookupSymbol mds ref)
    parse ((Nothing, _),_) = []
    parse ((Just (Node.LocalInfo{..}), txt),S{..}) = case Parser.run LiteralParser.term txt of
      Parser.Succeed tm n | all (== ' ') (drop n txt) -> do
        if isRight (Typechecker.check' tm localAdmissibleType)
          then [formatResult (lookupSymbol metadata) tm (Replace path tm, False) Right]
          else [formatResult (lookupSymbol metadata) tm () Left]
      _ -> []
    processQuery s localInfo txt selection = do
      let k (S {..}) = formatSearch (lookupSymbol metadata) path lastResults
      searches <- mapDyn k s
      locals <- combineDyn (\S{..} info -> formatLocals (lookupSymbol metadata) path info) s localInfo
      literals0 <- mapDynM (\p -> (,) p <$> sample (current s)) =<< combineDyn (,) localInfo txt
      literals <- mapDyn parse literals0
      -- todo - other actions
      keyed <- mconcatDyn [locals, searches, literals]
      let trimEnd = reverse . dropWhile (== ' ') . reverse
      let f possible txt = let txt' = trimEnd txt in filter (isPrefixOf txt' . fst) possible
      filtered <- combineDyn f keyed txt
      pure $
        let
          p (txt, rs) | any (== ';') txt = pure (Just Explorer.Cancel)
          p (txt, rs) | isSuffixOf "  " txt = fmap k <$> sample selection
           where k (a,_) = Explorer.Accept (a,True)
          p (_, rs) = pure (Just (Explorer.Results rs 0)) -- todo: track additional results count, via `S`
          -- todo - figuring when need to make remote requests
          -- just sample the current S; if we've got complete results for the last search (and it matches this one)
          -- we're good, otherwise issue a request if `txt` is currently firing
        in
        push p $ attachDyn txt (updated filtered)
    formatLocalInfo (i@Node.LocalInfo{..}) = i <$ do
      S {..} <- sample (current s)
      pure () -- todo, fill in with formatting of current, admissible type, etc
  in
    Explorer.explorer keydown processQuery (fmap formatLocalInfo localInfo) s

formatResult :: MonadWidget t m
             => (Reference -> Symbol View.DFO) -> Term V -> a -> (m a -> b) -> (String, b)
formatResult name e as w =
  let doc = Views.term name e
      txt = Text.unpack . Text.concat $ Doc.tokens "\n" (Doc.flow doc)
  in (txt, w (as <$ DocView.widget never (Dimensions.Width 300) doc))

formatLocals :: MonadWidget t m
             => (Reference -> Symbol View.DFO)
             -> Path
             -> Maybe (LocalInfo (Term V) (Type V))
             -> [(String, Either (m ()) (m (Action,Advance)))]
formatLocals name path results = fromMaybe [] $ go <$> results
  where
  view n = Term.var' "□" `Term.apps` replicate n Term.blank
  replace localTerm n = localTerm `Term.apps` replicate n Term.blank
  go (Node.LocalInfo {..}) =
    [ formatResult name e ((Replace path e),False) Right | e <- localVariableApplications ] ++
    [ formatResult name (view n) (Replace path (replace localTerm n),False) Right | n <- localOverapplications ]

formatSearch :: MonadWidget t m
             => (Reference -> Symbol View.DFO)
             -> Path
             -> Maybe (SearchResults V Reference (Term V))
             -> [(String, Either (m ()) (m (Action,Advance)))]
formatSearch name path results = fromMaybe [] $ go <$> results
  where
  go (Node.SearchResults {..}) =
    [ formatResult name e () Left | e <- fst illTypedMatches ] ++
    [ formatResult name e (Replace path e,False) Right | e <- fst matches ]
