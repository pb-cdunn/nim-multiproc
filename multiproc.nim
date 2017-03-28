# vim: sw=2 ts=2 sts=2 tw=80 et:

type
  Fork = ref object
  Pool = ref object
    forks: seq[Fork]

proc newPool*(n: int): Pool =
  new(result)
  newSeq(result.forks, n)
proc apply_async*(pool: Pool, f: proc()) =
  echo "no way"
  f()
