--
-- Basic.hs
--
-- Basic algebraic operations on expressions
--

module Math.Symbolic.Wheeler.Basic where


import Data.List


import {-# SOURCE #-} Math.Symbolic.Wheeler.Canonicalize
import {-# SOURCE #-} Math.Symbolic.Wheeler.Expr
import Math.Symbolic.Wheeler.Numeric



-- If an expression is a sum, return the list of terms, otherwise
-- return the expression unchanged.
--
terms :: Expr -> [ Expr ]
terms (Sum ts) = ts
terms e        = [e]


-- If an expression is a product, return the list of factors, otherwise
-- return the expression unchanged.
--
factors :: Expr -> [ Expr ]
factors (Product fs) = fs
factors e            = [e]


-- Canonicalization is deferred until after expansion to avoid
-- traversing the expression tree many times.
--
-- expand :: Expr -> Expr
-- expand = canonicalize . expand'


-- Note that in the second line, the argument to expand must be
-- (1 / f) * p instead of f / p.  This gives the correct result
-- for noncommutative factors.
--
expand :: Expr -> Expr
expand (Sum (t : []))     = expand t
expand (Sum (t : ts))     = expand t + expand (Sum ts)
expand (Product (f : [])) = expand f
expand (Product (f : fs)) = expandProduct (expand f) (expand (Product fs))
expand p@(Power b (Const (I n)))
  | n >= 2                = expandPower (expand b) n
  | otherwise             = p
expand e                  = e


-- This version of expandProduct does not assume the commutativity
-- of the factors.
--
expandProduct :: Expr -> Expr -> Expr
expandProduct (Sum (t : [])) s = expandProduct t s
expandProduct (Sum (t : ts)) s = (expandProduct t s) + expandProduct (Sum ts) s
expandProduct r (Sum (t : [])) = expandProduct r t
expandProduct r (Sum (t : ts)) = (expandProduct r t) + expandProduct r (Sum ts)
expandProduct r s              = let
                                    u = r * s
                                 in
                                    if hasSum (variables u) then expand u else u


expandPower :: Expr -> Integer -> Expr
expandPower s@(Sum ts) n =
  if allCommuting ts
  then expandPowerOfCommutingSum s n
  else expandPowerOfNoncommutingSum s n
expandPower u n = Power u (Const (I n))
               

allCommuting :: [ Expr ] -> Bool
allCommuting es = let
  (_ : nc) = groupFactors es
  in
   if null nc
   then True
   else all (\x -> length (snd x) < 2) nc
   

expandPowerOfCommutingSum :: Expr -> Integer -> Expr
expandPowerOfCommutingSum u@(Sum (t : _)) n =
    let
        r        = u - t
        coeff k  = (fromInteger (fact n)) / (fromInteger (fact k * fact (n - k)))
        newPow k = let
                       p = t**(fromInteger (n - k))
                   in
                       if hasSum (variables p) then expand p else p
    in
        foldl' (\s k -> s + expandProduct (coeff k * newPow k) (expandPower r k)) 0 [0 .. n]
expandPowerOfCommutingSum _ _ = error "expandPowerOfCommutingSum applied to non-Sum expression"


expandPowerOfNoncommutingSum :: Expr -> Integer -> Expr
expandPowerOfNoncommutingSum _ 0 = Const 1
expandPowerOfNoncommutingSum s 1 = s
expandPowerOfNoncommutingSum s@(Sum _) n =
  (expandProduct s s) * expand (Power s (fromInteger n - 2))
expandPowerOfNoncommutingSum _ _ = error "expandPowerOfNoncommutingSum applied to non-Sum expression"
  

-- Moderately efficient implementation of the factorial
-- function:
--
fact :: Integer -> Integer
fact n = fact' n 1
    where
        fact' 0 a = a
        fact' m a = fact' (m - 1) (a * m)



variables :: Expr -> [ Expr ]
variables (Const _) = []
variables p@(Power b (Const (I n)))
    | n > 1     = [b]
    | otherwise = [p]
variables p@(Power _ _) = [p]
variables (Sum ts)      = nub (concatMap termVariables ts)
variables (Product fs)  = nub (concatMap factorVariables fs)
variables e = [e]

termVariables :: Expr -> [ Expr ]
termVariables (Const _) = []
termVariables p@(Power b (Const (I n)))
    | n > 1     = [b]
    | otherwise = [p]
termVariables p@(Power _ _) = [p]
termVariables (Product fs)  = nub (concatMap factorVariables fs)
termVariables e = [e]

factorVariables :: Expr -> [ Expr ]
factorVariables (Const _) = []
factorVariables p@(Power b (Const (I n)))
    | n > 1     = [b]
    | otherwise = [p]
factorVariables p@(Power _ _) = [p]
factorVariables s@(Sum _)    = [s]
factorVariables e = [e]



hasSum :: [ Expr ] -> Bool
hasSum []          = False
hasSum (Sum _ : _) = True
hasSum (_ : es)    = hasSum es 



fractionParts :: Expr -> (Expr, Expr)
fractionParts (Product ts) = 
    let
        collectPowers :: [ Expr ] -> ([ Expr ], [ Expr ])
        collectPowers = partition (not . negPower)
            where
                negPower (Power _ (Const (I n)))
                     | n < 0     = True
                     | otherwise = False
                negPower (Power _ (Const (Q n _)))
                     | n < 0     = True
                     | otherwise = False
                negPower _ = False

        recipPower :: Expr -> Expr
        recipPower (Power b (Const (I n)))
            | n == -1   = b
            | otherwise = Power b (Const (negate (I n)))
        recipPower (Power b (Const (Q n d))) = Power b (Const (negate (Q n d)))
        recipPower _ = error "recipPower applied to non-power"

        (num, denom) = collectPowers ts
    in
        (Product num, Product (map recipPower denom))

fractionParts e = (e, Const 1)