module Core.Context

import Core.CompileExpr
import Core.Error
import Core.TT
import public Core.Context.Def
import public Core.Context.Ctxt

import Data.Either
import Data.List
import Data.List1
import Data.Maybe
import Data.Nat

import Libraries.Data.NameMap
import Libraries.Data.UserNameMap
import Libraries.Text.Distance.Levenshtein

getVisibility : {auto c : Ref Ctxt Defs} ->
                FC -> Name -> Core Visibility
getVisibility fc n
    = do defs <- get Ctxt
         Just def <- lookupCtxtExact n (gamma defs)
              | Nothing => throw (UndefinedName fc n)
         pure $ visibility def

-- Find similar looking names in the context
export
getSimilarNames : {auto c : Ref Ctxt Defs} ->
                   Name -> Core (Maybe (String, List (Name, Visibility, Nat)))
getSimilarNames nm = case show <$> userNameRoot nm of
  Nothing => pure Nothing
  Just str => if length str <= 1 then pure (Just (str, [])) else
    do defs <- get Ctxt
       let threshold : Nat := max 1 (assert_total (divNat (length str) 3))
       let test : Name -> Core (Maybe (Visibility, Nat)) := \ nm => do
               let (Just str') = show <$> userNameRoot nm
                   | _ => pure Nothing
               dist <- coreLift $ Levenshtein.compute str str'
               let True = dist <= threshold
                   | False => pure Nothing
               Just def <- lookupCtxtExact nm (gamma defs)
                   | Nothing => pure Nothing -- should be impossible
               pure (Just (visibility def, dist))
       kept <- mapMaybeM @{CORE} test (resolvedAs (gamma defs))
       pure $ Just (str, toList kept)

export
showSimilarNames : Namespace -> Name -> String ->
                   List (Name, Visibility, Nat) -> List String
showSimilarNames ns nm str kept
  = let (loc, priv) := partitionEithers $ kept <&> \ (nm', vis, n) =>
                         let False = fst (splitNS nm') `isParentOf` ns
                               | _ => Left (nm', n)
                             Private = vis
                               | _ => Left (nm', n)
                         in Right (nm', n)
        sorted      := sortBy (compare `on` snd)
        roots1      := mapMaybe (showNames nm str False . fst) (sorted loc)
        roots2      := mapMaybe (showNames nm str True  . fst) (sorted priv)
    in nub roots1 ++ nub roots2

  where

  showNames : Name -> String -> Bool -> Name -> Maybe String
  showNames target str priv nm = do
    let adj  = if priv then " (not exported)" else ""
    let root = nameRoot nm
    let True = str == root
      | _ => pure (root ++ adj)
    let full = show nm
    let True = (str == full || show target == full) && not priv
      | _ => pure (full ++ adj)
    Nothing

public export
data NoMangleDirective : Type where
    CommonName : String -> NoMangleDirective
    BackendNames : List (String, String) -> NoMangleDirective

public export
data DefFlag
    = Inline
    | NoInline
    | ||| A definition has been marked as deprecated
      Deprecate
    | Invertible -- assume safe to cancel arguments in unification
    | Overloadable -- allow ad-hoc overloads
    | TCInline -- always inline before totality checking
         -- (in practice, this means it's reduced in 'normaliseHoles')
         -- This means the function gets inlined when calculating the size
         -- change graph, but otherwise not. It's only safe if the function
         -- being inlined is terminating no matter what, and is really a bit
         -- of a hack to make sure interface dictionaries are properly inlined
         -- (otherwise they look potentially non terminating) so use with
         -- care!
    | SetTotal TotalReq
    | BlockedHint -- a hint, but blocked for the moment (so don't use)
    | Macro
    | PartialEval (List (Name, Nat)) -- Partially evaluate on completing defintion.
         -- This means the definition is standing for a specialisation so we
         -- should evaluate the RHS, with reduction limits on the given names,
         -- and ensure the name has made progress in doing so (i.e. has reduced
         -- at least once)
    | AllGuarded -- safe to treat as a constructor for the purposes of
         -- productivity checking. All clauses are guarded by constructors,
         -- and there are no other function applications
    | ConType ConInfo
         -- Is it a special type of constructor, e.g. a nil or cons shaped
         -- thing, that can be compiled specially?
    | Identity Nat
         -- Is it the identity function at runtime?
         -- The nat represents which argument the function evaluates to
    | NoMangle NoMangleDirective
         -- use the user provided name directly (backend, name)

export
Eq DefFlag where
    (==) Inline Inline = True
    (==) NoInline NoInline = True
    (==) Deprecate Deprecate = True
    (==) Invertible Invertible = True
    (==) Overloadable Overloadable = True
    (==) TCInline TCInline = True
    (==) (SetTotal x) (SetTotal y) = x == y
    (==) BlockedHint BlockedHint = True
    (==) Macro Macro = True
    (==) (PartialEval x) (PartialEval y) = x == y
    (==) AllGuarded AllGuarded = True
    (==) (ConType x) (ConType y) = x == y
    (==) (Identity x) (Identity y) = x == y
    (==) (NoMangle _) (NoMangle _) = True
    (==) _ _ = False

export
Show DefFlag where
  show Inline = "inline"
  show NoInline = "noinline"
  show Deprecate = "deprecate"
  show Invertible = "invertible"
  show Overloadable = "overloadable"
  show TCInline = "tcinline"
  show (SetTotal x) = show x
  show BlockedHint = "blockedhint"
  show Macro = "macro"
  show (PartialEval _) = "partialeval"
  show AllGuarded = "allguarded"
  show (ConType ci) = "contype " ++ show ci
  show (Identity x) = "identity " ++ show x
  show (NoMangle _) = "nomangle"

parameters {auto c : Ref Ctxt Defs}
  maybeMisspelling : Error -> Name -> Core a
  maybeMisspelling err nm = do
    ns <- currentNS <$> get Ctxt
    Just (str, kept) <- getSimilarNames nm
      | Nothing => throw err
    let candidates = showSimilarNames ns nm str kept
    case candidates of
      [] => throw err
      (x::xs) => throw (MaybeMisspelling err (x ::: xs))

  -- Throw an UndefinedName exception. But try to find similar names first.
  export
  undefinedName : FC -> Name -> Core a
  undefinedName loc nm = maybeMisspelling (UndefinedName loc nm) nm

  export
  aliasName : Name -> Core Name
  aliasName fulln
      = do defs <- get Ctxt
           let Just r = userNameRoot fulln
                  | Nothing => pure fulln
           let Just ps = lookup r (possibles (gamma defs))
                  | Nothing => pure fulln
           findAlias ps
    where
      findAlias : List PossibleName -> Core Name
      findAlias [] = pure fulln
      findAlias (Alias as full i :: ps)
          = if full == fulln
               then pure as
               else findAlias ps
      findAlias (_ :: ps) = findAlias ps
