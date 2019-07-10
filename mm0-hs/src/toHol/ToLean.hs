module ToLean (writeLean, Axioms(..)) where

import Data.Foldable
import Data.Semigroup
import System.FilePath
import System.IO
import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import Environment (Ident)
import HolTypes
import Util

data LeanState = LeanState {
  lChunk :: Int,
  lFileName :: String,
  lHandle :: Handle,
  lIndex :: Int,
  lChunkSize :: Int,
  lHyps :: M.Map Ident [Ident] }

type LeanM = StateT LeanState IO

data Axioms = FromFile String | Regular | Only deriving (Eq)

axFile :: Axioms -> Maybe String
axFile (FromFile s) = Just s
axFile _ = Nothing

noAx :: Axioms -> Bool
noAx (FromFile s) = True
noAx _ = False

writeLean :: Axioms -> String -> Int -> [HDecl] -> IO ()
writeLean ax fname chunkSize ds =
  evalStateT (open (axFile ax) >> mapM_ (\d -> leanDecl ax d >> increment) ds >> close) $
    LeanState 1 fname undefined 0 chunkSize M.empty

emit :: String -> LeanM ()
emit s = do g <- get; lift $ hPutStrLn (lHandle g) s

fname :: String -> Int -> String
fname bn 1 = bn
fname bn n = bn ++ show n

open :: Maybe String -> LeanM ()
open i = do
  g <- get
  let fn = lFileName g
  let name = takeDirectory fn </> fname (takeBaseName fn) (lChunk g) <.> "lean"
  h <- lift $ openFile name WriteMode
  lift $ hSetEncoding h utf8
  put $ g {lHandle = h}
  emit $ "-- Autogenerated from MM0\n"
  forM_ i $ \f -> emit $ "import " ++ f ++ "\n"
  emit "namespace mm0\n"

close :: LeanM ()
close = do
  emit "end mm0"
  g <- get
  lift $ hClose (lHandle g)
  put $ g {lHandle = undefined}

preamble :: LeanM () -> LeanM ()
preamble m = emit "namespace mm0\n" >> m >> emit "end mm0"

mangle :: T.Text -> ShowS
mangle "fun" r = '\x00AB' : "fun\x00BB" ++ r
mangle "class" r = '\x00AB' : "class\x00BB" ++ r
mangle s r = case T.uncons s of
  Just ('_', s') -> '\x00AB' : T.unpack s' ++ '\x00BB' : r
  _ -> T.unpack s ++ r

increment :: LeanM ()
increment = do
  g <- get
  if lIndex g + 1 < lChunkSize g then
    put $ g {lIndex = lIndex g + 1}
  else do
    close
    put $ g {lChunk = lChunk g + 1, lIndex = 0}
    open $ Just ('.' : fname (takeBaseName (lFileName g)) (lChunk g))

printSType :: Bool -> SType -> ShowS
printSType p (SType [] s) = mangle s
printSType p (SType ss s) = showParen p $
  \r -> foldr (\x -> mangle x . (" \x2192 " ++)) (mangle s r) ss

printHType :: HType -> ShowS
printHType (HType [] s) r = printSType False s r
printHType (HType ss s) r =
  foldr (\x -> printSType True x . (" \x2192 " ++)) (printSType False s r) ss

printBinderGroup :: Bool -> [Ident] -> ShowS -> ShowS
printBinderGroup True ls pr r =
  " {" ++ foldr (\i -> mangle i . (' ' :)) (": " ++ pr ('}' : r)) ls
printBinderGroup False ls pr r =
  " (" ++ foldr (\i -> mangle i . (' ' :)) (": " ++ pr (')' : r)) ls

printGroupedBinders :: Bool -> [(Ident, SType)] -> ShowS
printGroupedBinders p bis r =
  foldr (\(gr, ty) -> printBinderGroup p  gr (printSType False ty)) r (join bis Nothing)
  where
  join :: [(Ident, SType)] -> Maybe ([Ident], SType) -> [([Ident], SType)]
  join [] o = flush o []
  join ((x, ty) : bis) (Just (xs, ty')) | ty == ty' =
    join bis (Just (x : xs, ty'))
  join ((x, ty) : bis) o = flush o (join bis (Just ([x], ty)))

  flush :: Maybe ([Ident], SType) -> [([Ident], SType)] -> [([Ident], SType)]
  flush Nothing l = l
  flush (Just (xs, ty)) l = (reverse xs, ty) : l

shortBinds :: Char -> [(Ident, Sort)] -> ShowS
shortBinds c vs r = c : foldr (\(v, _) -> (' ' :) . mangle v) (", " ++ r) vs

printSLam :: Bool -> SLam -> ShowS
printSLam p (SLam [] e) = printTerm p e
printSLam p (SLam vs e) = showParen p $ shortBinds '\x03BB' vs . printTerm False e

printTerm :: Bool -> Term -> ShowS
printTerm p (LVar v) = mangle v
printTerm p (RVar v []) = mangle v
printTerm p (RVar v xs) = showParen p $
  mangle v . flip (foldr (\x -> (' ' :) . mangle x)) xs
printTerm p (HApp t [] []) = mangle t
printTerm p (HApp t es xs) = showParen p $ mangle t .
  flip (foldr (\e -> (' ' :) . printSLam True e)) es .
  flip (foldr (\x -> (' ' :) . mangle x)) xs
printTerm p HTSorry = ("sorry" ++)

printGType :: Bool -> GType -> ShowS
printGType _ (GType [] e) = ("\x22A6 " ++) . printTerm False e
printGType p (GType vs e) = showParen p $
  shortBinds '\x2200' vs . ("\x22A6 " ++) . printTerm False e

printProofLam :: Bool -> String -> HProofLam -> ShowS
printProofLam p n (HProofLam [] e) = printProof p n e
printProofLam p n (HProofLam vs e) = showParen p $
  shortBinds '\x03BB' vs . printProof False n e

printProof :: Bool -> String -> HProof -> ShowS
printProof p n (HHyp v []) = mangle v
printProof p n (HHyp v xs) = showParen p $
  (T.unpack v ++) . flip (foldr (\x -> (' ' :) . mangle x)) xs
printProof p n (HThm t [] [] []) = mangle t
printProof p n (HThm t es hs xs) = showParen p $ ('@' :) . mangle t .
  flip (foldr (\e -> (' ' :) . printSLam True e)) es .
  let n' = "  " ++ n in
  flip (foldr (\e -> (('\n' : n') ++) . printProofLam True n' e)) hs .
  flip (foldr (\x -> (' ' :) . mangle x)) xs
-- printProof p n (HSave v pr xs) = showParen p $ \r ->
--   "let " ++ mangle v (" := " ++ printProofLam False pr (" in " ++ shows (HHyp v xs) r))
printProof p n (HForget t (HProofLam vs pr)) = showParen p $ \r ->
  let n' = "  " ++ n in
  foldr (\(v, s) -> (mangle s ".forget $ \x03BB " ++) .
      mangle v . (" : " ++) . mangle s . ((",\n" ++ n') ++))
    ("show \x22A6 " ++ printTerm False t (", from\n" ++ n' ++ printProof False n' pr r)) vs
printProof p n (HConv _ pr) = printProof p n pr
printProof p n HSorry = ("sorry" ++)

emitLet :: Ident -> HProofLam -> LeanM ()
emitLet v pr = emit $ "let " ++ mangle v (" := " ++ printProofLam False "" pr " in")

unsaveProof :: [(Ident, Sort)] -> HProof -> LeanM (S.Set Ident, HProof)
unsaveProof ctx p@(HHyp v vs) = do
  g <- get
  case lHyps g M.!? v of
    Nothing -> return (S.fromList vs, p)
    Just vs1 -> let vs' = vs1 ++ vs in return (S.fromList vs', HHyp v vs')
unsaveProof ctx (HThm t es hs xs) = do
  let s1 = foldMap fvLLam es
  (ss2, hs') <- unzip <$> mapM (unsaveProofLam ctx) hs
  return (s1 <> fold ss2 <> S.fromList xs, HThm t es hs' xs)
unsaveProof ctx (HSave v p xs) = do
  (s, HProofLam bis2 p') <- unsaveProofLam ctx p
  let go s' [] bis1 bis2 xs = (bis1, bis2, xs)
      go s' (vt@(x, _) : ctx) bis1 bis2 xs =
        if S.member x s && S.notMember x s' then
          go (S.insert x s') ctx (x : bis1) (vt : bis2) (x : xs)
        else go s' ctx bis1 bis2 xs
      (bis1, bis', xs') = go S.empty ctx [] bis2 xs
  emitLet v (HProofLam bis' p')
  modify $ \g -> g {lHyps = M.insert v bis1 (lHyps g)}
  return (s, HHyp v xs')
unsaveProof ctx (HForget t p) = mapSnd (HForget t) <$> unsaveProofLam ctx p
unsaveProof ctx (HConv c p) = mapSnd (HConv c) <$> unsaveProof ctx p
unsaveProof ctx HSorry = return (S.empty, HSorry)

unsaveProofLam :: [(Ident, Sort)] -> HProofLam -> LeanM (S.Set Ident, HProofLam)
unsaveProofLam ctx (HProofLam vs p) = go ctx vs where
  go ctx [] = mapSnd (HProofLam []) <$> unsaveProof ctx p
  go ctx (vt@(v, _) : vs) = do
    (s, HProofLam vs' p') <- go (vt : ctx) vs
    return (S.delete v s, HProofLam (vt : vs') p')

leanDecl :: Axioms -> HDecl -> LeanM ()
leanDecl ax (HDSort s) = do
  let s' = mangle s
  let c = if noAx ax then ("-- " ++) else id
  emit $ c $ "constant " ++ s' " : Type\n"
  emit $ c $ "constant " ++ s' ".proof : " ++ s' " \x2192 Prop"
  emit $ c $ "prefix `\x22A6 `:26 := " ++ s' ".proof"
  emit $ c $ "constant " ++ s' ".forget {p : Prop} : (" ++ s' " \x2192 p) \x2192 p"
leanDecl ax (HDTerm x ty) = do
  let c = if noAx ax then ("-- " ++) else id
  emit $ c $ "constant " ++ mangle x " : " ++ printHType ty "\n"
leanDecl ax (HDDef x ss xs r t) = when (ax /= Only) $
  let bis = printGroupedBinders False (ss ++ (mapSnd (SType []) <$> xs)) in
  emit $ ("def " ++) $ mangle x $ bis (" : " ++ T.unpack r ++ " :=\n" ++ printTerm False t "\n")
leanDecl ax (HDThm x (TType vs gs ret) Nothing) = do
  let c = if noAx ax then ("-- " ++) else id
  emit $ c $ ("axiom " ++) $ mangle x $ printGroupedBinders True vs $ " : " ++
    foldr (\g r -> printGType True g (" \x2192 " ++ r)) (printGType False ret "\n") gs
leanDecl ax (HDThm x (TType vs gs (GType xs ret)) (Just (hs, pr))) = when (ax /= Only) $ do
  let bis1 = printGroupedBinders True vs
  let bis2 r = foldr (\(h, g) -> ("\n " ++) .
        printBinderGroup False [h] (printGType False g)) r (zip hs gs)
  let bis3 = if null xs then (" :\n " ++) else
        ("\n " ++) . printGroupedBinders False (mapSnd (SType []) <$> xs) . (" :" ++)
  emit $ ("theorem " ++) $ mangle x $ bis1 $ bis2 $ bis3 $ " \x22A6 " ++ printTerm False ret " :="
  (_, pr') <- unsaveProof (reverse xs) pr
  modify $ \g -> g {lHyps = M.empty}
  emit $ printProof False "" pr' "\n"
