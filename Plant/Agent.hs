module Agent where

data Env = Env
    { psim  :: Double
    , frepr :: Double
    } deriving (Show)

data Attrs = Attrs
  { ind :: Int
  , psi :: Double
  , fi  :: Double
  } deriving (Eq, Ord, Show)

data Agent =
    Seed { mass :: Double
         , attr :: Attrs
         , dg :: Double
         , art :: Double}
    | Leaf { attr :: Attrs
           , i :: Int
           , ta :: Double
           , m :: Double
           , a :: Double}
    | Cell { attr :: Attrs
           , c :: Double
           , s :: Double}
    | Root { attr :: Attrs
           , m :: Double}
    | Plant { thrt :: Double
            , attr :: Attrs
            , dg :: Double
            , wct :: Double}
    | EPlant { sdeg :: Double
             , thrt :: Double
             , attr :: Attrs
             , dg :: Double
             , wct :: Double}
    | FPlant { attr :: Attrs
             , dg :: Double}
    deriving (Eq, Show)

-- instance Eq Agent where
--   (==) Seed{attr=a} Seed{attr=a'} = ind a == ind a'
--   (==) Leaf{attr=a, i=i} Leaf{attr=a', i=i'} = (ind a == ind a') && (i == i')
--   (==) Cell{attr=a} Cell{attr=a'} = ind a == ind a'
--   (==) Root{attr=a} Root{attr=a'} = ind a == ind a'
--   (==) Plant{attr=a} Plant{attr=a'} = ind a == ind a'
--   (==) EPlant{attr=a} EPlant{attr=a'} = ind a == ind a'
--   (==) FPlant{attr=a} FPlant{attr=a'} = ind a == ind a'
--   (==) _ _ = False

--   (/=) a a' = not ((==) a a')

isCell (Cell{c=c}) = True
isCell _ = False

isLeaf :: Agent -> Bool
isLeaf Leaf {} = True
isLeaf _ = False

isPlant :: Agent -> Bool
isPlant (Plant{}) = True
isPlant _ = False

isEPlant :: Agent -> Bool
isEPlant (EPlant{}) = True
isEPlant _ = False

isFPlant :: Agent -> Bool
isFPlant (FPlant{}) = True
isFPlant _ = False

isSeed :: Agent -> Bool
isSeed (Seed{}) = True
isSeed _ = False
