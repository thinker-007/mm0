{
module Parser (parse) where
import AST
import Lexer
import Control.Monad.Except
import Text.Read
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
}

%monad{Alex}
%lexer{lexer}{TokEOF}
%name mparse
%tokentype{Token}
%error {parseError}

%token
  axiom     {TokAxiom}
  coercion  {TokCoercion}
  def       {TokDef}
  delimiter {TokDelimiter}
  free      {TokFree}
  infix     {TokInfix $$}
  max       {TokMax}
  notation  {TokNotation}
  output    {TokOutput}
  prec      {TokPrec}
  prefix    {TokPrefix}
  provable  {TokProvable}
  pure      {TokPure}
  sort      {TokSort}
  strict    {TokStrict}
  term      {TokTerm}
  theorem   {TokTheorem}
  var       {TokVar}
  ident     {TokIdent $$}
  number    {TokNumber $$}
  formula   {TokFormula $$}
  '*'       {TokStar}
  '.'       {TokDot}
  ':'       {TokColon}
  ';'       {TokSemi}
  '('       {TokLParen}
  ')'       {TokRParen}
  '>'       {TokArrow}
  '{'       {TokLBrace}
  '}'       {TokRBrace}
  '='       {TokEqual}
  '_'       {TokAnon}


%%

Spec  : list(Directive) {$1}

Directive : Statement {$1} | '{' list(Directive) '}' {Block $2}

Statement : SortStmt {$1}
          | VarStmt {$1}
          | TermStmt {$1}
          | AssertStmt {$1}
          | DefStmt {$1}
          | NotationStmt {Notation $1}
          | OutputStmt {$1}

Ident : ident {$1}
      | axiom {"axiom"}
      | coercion {"coercion"}
      | def {"def"}
      | delimiter {"delimiter"}
      | infix {if $1 then "infixr" else "infixl"}
      | max {"max"}
      | free {"free"}
      | notation {"notation"}
      | output {"output"}
      | prec {"prec"}
      | prefix {"prefix"}
      | provable {"provable"}
      | pure {"pure"}
      | sort {"sort"}
      | strict {"strict"}
      | term {"term"}
      | theorem {"theorem"}
      | var {"var"}

SortStmt : flag(pure) flag(strict) flag(provable) flag(free)
             sort Ident ';' {Sort $6 (SortData $1 $2 $3 $4)}

VarStmt : var list(Ident) ':' VarType ';' {Var $2 $4}
VarType : Ident {VTReg $1}
        | Ident '*' {Open $1}

TermStmt : term Ident binders(Ident_, TType) ':' ArrowType ';'
           {unArrow (Term $2) $3 $5}
Ident_ : Ident {LReg $1} | '_' {LAnon}
Type : Ident list(Ident) {DepType $1 $2}
TType : Type {TType $1}
ArrowType : Type {arrow1 $1} | TType '>' ArrowType {arrowCons $1 $3}

AssertStmt : AssertKind Ident binders(Ident_, TypeFmla) ':' FmlaArrowType ';'
             {unArrow ($1 $2) $3 $5}
AssertKind : axiom {Axiom} | theorem {Theorem}
TypeFmla : Type {TType $1} | formula {TFormula $1}
FmlaArrowType : formula {arrow1 $1}
              | TypeFmla '>' FmlaArrowType {arrowCons $1 $3}

DefStmt : def Ident binders(Dummy, TType) ':' Type OptDef ';' {Def $2 $3 $5 $6}
OptDef : '=' formula {Just $2} | {Nothing}
Dummy : '.' Ident {LDummy $2} | Ident_ {$1}

NotationStmt : DelimiterStmt {$1}
             | SimpleNotationStmt {$1}
             | CoercionStmt {$1}
             | GenNotationStmt {$1}

DelimiterStmt : delimiter formula ';' {Delimiter $2}
SimpleNotationStmt : NotationKind Ident ':' Constant prec Precedence ';' {$1 $2 $4 $6}
NotationKind : prefix {Prefix} | infix {Infix $1}
Constant : formula {$1}
Precedence : number {% parseInt $1} | max {maxBound}

CoercionStmt : coercion Ident ':' Ident '>' Ident ';' {Coercion $2 $4 $6}
GenNotationStmt : notation Ident binders(Ident_, TType) ':' Type '=' list1(Literal) ';'
                  {NNotation $2 $3 $5 $7}
Literal : '(' Constant ':' Precedence ')' {NConst $2 $4} | Ident {NVar $1}

OutputStmt : output OutputKind Ident binders(Dummy, TypeFmla) ';' {Output $2 $3 $4}
OutputKind : Ident {$1}

flag(p) : p {True} | {False}
list(p) : {[]} | p list(p) {$1 : $2}
list1(p) : p list(p) {$1 : $2}
binder(p, q) : '(' list(p) ':' q ')' {($2, $4)}
             | '{' list(p) ':' q '}' {(map toBound $2, $4)}
binders(p, q) : list(binder(p, q)) {joinBinders $1}

{

parseError :: Token -> Alex a
parseError s = failLC ("Parse error: " ++ show s)

parseInt :: String -> Alex Int
parseInt s = case (readMaybe s :: Maybe Integer) of
  Nothing -> failLC ("not an integer: '" ++ s ++ "'")
  Just n ->
    if n > fromIntegral (maxBound :: Int) then
      failLC ("out of range: '" ++ s ++ "'")
    else
      pure (fromIntegral n)

toBound :: Local -> Local
toBound (LReg v) = LBound v
toBound v = v

joinBinders :: [([Local], Type)] -> [Binder]
joinBinders = concatMap $ \(ls, ty) -> (\l -> Binder l ty) <$> ls

type ArrowType a = ([Binder] -> [Binder], a)

arrow1 :: a -> ArrowType a
arrow1 ty = (id, ty)

arrowCons :: Type -> ArrowType a -> ArrowType a
arrowCons ty1 (f, ty) = (f . (Binder LAnon ty1 :), ty)

unArrow :: ([Binder] -> a -> b) -> [Binder] -> ArrowType a -> b
unArrow f bs (g, ty) = f (g bs) ty

parse :: L.ByteString -> Either String [Stmt]
parse = runAlex mparse

}
