add : Int -> Int -> Int
add = \x -> \y -> x + y

main : Int
main =
  let add5 = add 5 in
  add5 3
