import std/macros
import std/unicode
import std/tables
from std/strutils import find

import ./nodetype
import ./nfatype
import ./compiler
import ./nfafindalltype
import ./nodematchmacro

macro defVars(idns: varargs[untyped]): untyped =
  var lets = newNimNode nnkLetSection
  for idn in idns:
    lets.add newIdentDefs(
      idn, newEmptyNode(), newCall("genSym", newLit nskVar, newLit $idn))
  return newStmtList lets

func genMatchedBody(
  smA, smB, m, ntLit, capt, bounds,
  matched, captx, eoeFound, smi,
  capts, charIdx, cPrev, c: NimNode,
  i, nti, nt: int,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.nfa
  template tns: untyped = regex.transitions
  let matchedStmt = case nfa[nt].kind:
    of reEoe:
      quote do:
        `m`.add (`captx`, `bounds`.a .. `charIdx`-1)
        `smA`.clear()
        if not `eoeFound`:
          `eoeFound` = true
          `smA`.add (0'i16, -1'i32, `charIdx` .. `charIdx`-1)
        `smi` = 0
        continue
    else:
      quote do:
        add(`smB`, (`ntLit`, `captx`, `bounds`.a .. `charIdx`-1))
  if tns.allZ[i][nti] == -1'i16:
    return matchedStmt
  var matchedBody: seq[NimNode]
  matchedBody.add quote do:
    `matched` = true
    `captx` = `capt`
  for z in tns.z[tns.allZ[i][nti]]:
    case z.kind
    of groupKind:
      let zIdx = newLit z.idx
      matchedBody.add quote do:
        add(`capts`, CaptNode(
          parent: `captx`,
          bound: `charIdx`,
          idx: `zIdx`))
        `captx` = (len(`capts`) - 1).int32
    of assertionKind:
      let matchCond = genMatch(z, cPrev, c)
      matchedBody.add quote do:
        `matched` = `matched` and `matchCond`
    else:
      doAssert false
  matchedBody.add quote do:
    if `matched`:
      `matchedStmt`
  return newStmtList matchedBody

func genSubmatch(
  n, capt, bounds, smA, smB, m, c,
  matched, captx, eoeFound, smi,
  capts, charIdx, cPrev: NimNode,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.nfa
  result = newStmtList()
  var caseStmtN: seq[NimNode]
  caseStmtN.add n
  for i in 0 .. nfa.len-1:
    if nfa[i].kind == reEoe:
      continue
    var branchBodyN: seq[NimNode]
    for nti, nt in nfa[i].next.pairs:
      let matchCond = case nfa[nt].kind
        of reEoe:
          quote do: true
        of reInSet:
          let m = genSetMatch(c, nfa[nt])
          quote do: `c` >= 0'i32 and `m`
        of reNotSet:
          let m = genSetMatch(c, nfa[nt])
          quote do: `c` >= 0'i32 and not `m`
        else:
          let m = genMatch(c, nfa[nt])
          quote do: `c` >= 0'i32 and `m`
      let ntLit = newLit nt
      let matchedBodyStmt = genMatchedBody(
        smA, smB, m, ntLit, capt, bounds,
        matched, captx, eoeFound, smi,
        capts, charIdx, cPrev, c,
        i, nti, nt, regex)
      branchBodyN.add quote do:
        if not hasState(`smB`, `ntLit`) and `matchCond`:
          `matchedBodyStmt`
    doAssert branchBodyN.len > 0
    caseStmtN.add newTree(nnkOfBranch,
      newLit i.int16,
      newStmtList(
        branchBodyN))
  doAssert caseStmtN.len > 1
  caseStmtN.add newTree(nnkElse,
    quote do:
      doAssert false
      discard)
  result.add newTree(nnkCaseStmt, caseStmtN)

func submatch(
  regex: Regex,
  ms, charIdx, cPrev, c: NimNode
): NimNode =
  defVars captx, matched, eoeFound, smi
  let smA = quote do: `ms`.a
  let smB = quote do: `ms`.b
  let capts = quote do: `ms`.c
  let m = quote do: `ms`.m
  let n = quote do: `ms`.a[`smi`].ni
  let capt = quote do: `ms`.a[`smi`].ci
  let bounds = quote do: `ms`.a[`smi`].bounds
  let submatchStmt = genSubmatch(
    n, capt, bounds, smA, smB, m, c,
    matched, captx, eoeFound, smi,
    capts, charIdx, cPrev, regex)
  result = quote do:
    `smB`.clear()
    var `captx`: int32
    var `matched` = true
    var `eoeFound` = false
    var `smi` = 0
    while `smi` < `smA`.len:
      `submatchStmt`
      `smi` += 1
    swap `smA`, `smB`

func genSubmatchEoe(
  n, capt, bounds, smA, smB, m,
  matched, captx, eoeFound, smi,
  capts, charIdx, cPrev: NimNode,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.nfa
  result = newStmtList()
  var caseStmtN: seq[NimNode]
  caseStmtN.add n
  for i in 0 .. nfa.len-1:
    if nfa[i].kind == reEoe:
      continue
    var branchBodyN: seq[NimNode]
    for nti, nt in nfa[i].next.pairs:
      if nfa[nt].kind == reEoe:
        let ntLit = newLit nt
        let cLit = newLit -1'i32
        let matchedBodyStmt = genMatchedBody(
          smA, smB, m, ntLit, capt, bounds,
          matched, captx, eoeFound, smi,
          capts, charIdx, cPrev, cLit,
          i, nti, nt, regex)
        branchBodyN.add quote do:
          if not hasState(`smB`, `ntLit`):
            `matchedBodyStmt`
    if branchBodyN.len > 0:
      caseStmtN.add newTree(nnkOfBranch,
        newLit i.int16,
        newStmtList(
          branchBodyN))
  doAssert caseStmtN.len > 1
  caseStmtN.add newTree(nnkElse,
    quote do: discard)
  result.add newTree(nnkCaseStmt, caseStmtN)

func submatchEoe(
  regex: Regex,
  ms, charIdx, cPrev: NimNode
): NimNode =
  defVars captx, matched, eoeFound, smi
  let smA = quote do: `ms`.a
  let smB = quote do: `ms`.b
  let capts = quote do: `ms`.c
  let m = quote do: `ms`.m
  let n = quote do: `ms`.a[`smi`].ni
  let capt = quote do: `ms`.a[`smi`].ci
  let bounds = quote do: `ms`.a[`smi`].bounds
  let submatchStmt = genSubmatchEoe(
    n, capt, bounds, smA, smB, m,
    matched, captx, eoeFound, smi,
    capts, charIdx, cPrev, regex)
  result = quote do:
    `smB`.clear()
    var `captx`: int32
    var `matched` = true
    var `eoeFound` = false
    var `smi` = 0
    while `smi` < `smA`.len:
      `submatchStmt`
      `smi` += 1
    swap `smA`, `smB`

proc findSomeImpl(
  text, ms, i, isOpt: NimNode,
  regex: Regex
): NimNode =
  defVars c, cPrev, iPrev
  let nfaLenLit = newLit regex.nfa.len
  let smA = quote do: `ms`.a
  let c2 = quote do: int32(`c`)
  let submatchStmt = submatch(regex, ms, iPrev, cPrev, c2)
  let submatchEoeStmt = submatchEoe(regex, ms, iPrev, cPrev)
  return quote do:
    initMaybeImpl(`ms`, `nfaLenLit`)
    `ms`.clear()
    var
      `c` = Rune(-1)
      `cPrev` = -1'i32
      `iPrev` = `i`
    `smA`.add (0'i16, -1'i32, `i` .. `i`-1)
    if 0 <= `i`-1 and `i`-1 <= len(`text`)-1:
      `cPrev` = bwRuneAt(`text`, `i`-1).int32
    while `i` < len(`text`):
      fastRuneAt(`text`, `i`, `c`, true)
      `submatchStmt`
      if `smA`.len == 0:
        if `i` < len(`text`):
          if hasMatches(`ms`) or `isOpt`:
            break
      `smA`.add (0'i16, -1'i32, `i` .. `i`-1)
      `iPrev` = `i`
      `cPrev` = `c`.int32
    if `i` >= len(`text`):
      `submatchEoeStmt`
      doAssert `smA`.len == 0
      if not hasMatches(`ms`):
        `i` = -1

func genMatchedBody2(
  smA, smB, m, ntLit, capt, bounds,
  matched, smi,
  capts, charIdx, cPrev, c: NimNode,
  i, nti, nt: int,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.litOpt.nfa
  template tns: untyped = regex.litOpt.tns
  let matchedStmt = case nfa[nt].kind:
    of reEoe:
      quote do:
        add(`smB`, (`ntLit`, `capt`, `charIdx` .. `bounds`.b))
        break
    else:
      quote do:
        add(`smB`, (`ntLit`, `capt`, `charIdx` .. `bounds`.b))
  if tns.allZ[i][nti] == -1'i16:
    return matchedStmt
  var matchedBody: seq[NimNode]
  matchedBody.add quote do:
    `matched` = true
  for z in tns.z[tns.allZ[i][nti]]:
    case z.kind
    of assertionKind:
      let matchCond = genMatch(z, c, cPrev)
      matchedBody.add quote do:
        `matched` = `matched` and `matchCond`
    else:
      doAssert false
  matchedBody.add quote do:
    if `matched`:
      `matchedStmt`
  return newStmtList matchedBody

func genEoeBailOut(
  n, capt, bounds, smB: NimNode,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.litOpt.nfa
  result = newStmtList()
  # XXX can there be more than one eoe?
  var caseStmtN: seq[NimNode]
  caseStmtN.add n
  for i in 0 .. nfa.len-1:
    if nfa[i].kind != reEoe:
      continue
    var branchBodyN = quote do:
      `smB`.add (`n`, `capt`, `bounds`)
      break
    caseStmtN.add newTree(nnkOfBranch,
      newLit i.int16,
      newStmtList(
        branchBodyN))
  doAssert caseStmtN.len > 1
  caseStmtN.add newTree(nnkElse,
    quote do: discard)
  result.add newTree(nnkCaseStmt, caseStmtN)

func genSubmatch2(
  n, capt, bounds, smA, smB, m, c,
  matched, smi,
  capts, charIdx, cPrev: NimNode,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.litOpt.nfa
  result = newStmtList()
  var caseStmtN: seq[NimNode]
  caseStmtN.add n
  for i in 0 .. nfa.len-1:
    if nfa[i].kind == reEoe:
      continue
    var branchBodyN: seq[NimNode]
    for nti, nt in nfa[i].next.pairs:
      let matchCond = case nfa[nt].kind
        of reEoe:
          quote do: true
        of reInSet:
          let m = genSetMatch(c, nfa[nt])
          quote do: `c` >= 0'i32 and `m`
        of reNotSet:
          let m = genSetMatch(c, nfa[nt])
          quote do: `c` >= 0'i32 and not `m`
        else:
          let m = genMatch(c, nfa[nt])
          quote do: `c` >= 0'i32 and `m`
      let ntLit = newLit nt
      let matchedBodyStmt = genMatchedBody2(
        smA, smB, m, ntLit, capt, bounds,
        matched, smi,
        capts, charIdx, cPrev, c,
        i, nti, nt, regex)
      branchBodyN.add quote do:
        if not hasState(`smB`, `ntLit`) and `matchCond`:
          `matchedBodyStmt`
    doAssert branchBodyN.len > 0
    caseStmtN.add newTree(nnkOfBranch,
      newLit i.int16,
      newStmtList(
        branchBodyN))
  doAssert caseStmtN.len > 1
  caseStmtN.add newTree(nnkElse,
    quote do:
      doAssert false
      discard)
  result.add newTree(nnkCaseStmt, caseStmtN)

func submatch2(
  regex: Regex,
  ms, charIdx, cPrev, c: NimNode
): NimNode =
  defVars matched, smi
  let smA = quote do: `ms`.a
  let smB = quote do: `ms`.b
  let capts = quote do: `ms`.c
  let m = quote do: `ms`.m
  let n = quote do: `ms`.a[`smi`].ni
  let capt = quote do: `ms`.a[`smi`].ci
  let bounds = quote do: `ms`.a[`smi`].bounds
  let submatchStmt = genSubmatch2(
    n, capt, bounds, smA, smB, m, c,
    matched, smi,
    capts, charIdx, cPrev, regex)
  let eoeBailOutStmt = genEoeBailOut(
    n, capt, bounds, smB, regex)
  result = quote do:
    `smB`.clear()
    var `matched` = true
    var `smi` = 0
    while `smi` < `smA`.len:
      `eoeBailOutStmt`
      `submatchStmt`
      `smi` += 1
    swap `smA`, `smB`

func genSubmatchEoe2(
  n, capt, bounds, smA, smB, m, c,
  matched, smi,
  capts, charIdx, cPrev: NimNode,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.litOpt.nfa
  result = newStmtList()
  var caseStmtN: seq[NimNode]
  caseStmtN.add n
  for i in 0 .. nfa.len-1:
    var branchBodyN: seq[NimNode]
    for nti, nt in nfa[i].next.pairs:
      if nfa[nt].kind == reEoe:
        let ntLit = newLit nt
        let matchedBodyStmt = genMatchedBody2(
          smA, smB, m, ntLit, capt, bounds,
          matched, smi,
          capts, charIdx, cPrev, c,
          i, nti, nt, regex)
        branchBodyN.add quote do:
          if not hasState(`smB`, `ntLit`):
            `matchedBodyStmt`
    if branchBodyN.len > 0:
      caseStmtN.add newTree(nnkOfBranch,
        newLit i.int16,
        newStmtList(
          branchBodyN))
  doAssert caseStmtN.len > 1
  caseStmtN.add newTree(nnkElse,
    quote do: discard)
  result.add newTree(nnkCaseStmt, caseStmtN)

func submatchEoe2(
  regex: Regex,
  ms, charIdx, cPrev, c: NimNode
): NimNode =
  defVars matched, smi
  let smA = quote do: `ms`.a
  let smB = quote do: `ms`.b
  let capts = quote do: `ms`.c
  let m = quote do: `ms`.m
  let n = quote do: `ms`.a[`smi`].ni
  let capt = quote do: `ms`.a[`smi`].ci
  let bounds = quote do: `ms`.a[`smi`].bounds
  let submatchStmt = genSubmatchEoe2(
    n, capt, bounds, smA, smB, m, c,
    matched, smi,
    capts, charIdx, cPrev, regex)
  let eoeBailOutStmt = genEoeBailOut(
    n, capt, bounds, smB, regex)
  result = quote do:
    `smB`.clear()
    var `matched` = true
    var `smi` = 0
    while `smi` < `smA`.len:
      `eoeBailOutStmt`
      `submatchStmt`
      `smi` += 1
    swap `smA`, `smB`

# XXX move
template bwFastRuneAt(
  s: string, n: var int, result: var Rune
) =
  ## Take rune ending at ``n``
  doAssert n > 0
  doAssert n <= s.len-1
  dec n
  while n > 0 and s[n].ord shr 6 == 0b10:
    dec n
  fastRuneAt(s, n, result, false)

func matchPrefixImpl(
  text, ms, i, limit: NimNode,
  regex: Regex
): NimNode =
  template nfa: untyped = regex.litOpt.nfa
  defVars c, cPrev, iPrev
  var eoe = -1
  for i in 0 .. nfa.len-1:
    if nfa[i].kind == reEoe:
      doAssert eoe == -1
      eoe = i
  doAssert eoe > -1
  let eoeLit = newLit eoe
  let smA = quote do: `ms`.a
  let smB = quote do: `ms`.b
  let c2 = quote do: int32(`c`)
  let submatchStmt = submatch2(regex, ms, iPrev, cPrev, c2)
  let submatchEoeStmt = submatchEoe2(regex, ms, iPrev, cPrev, c2)
  return quote do:
    doAssert `i` < len(`text`)
    doAssert `i` >= `limit`
    `smA`.clear()
    `smB`.clear()
    var
      `c` = Rune(-1)
      `cPrev` = runeAt(`text`, `i`).int32
      `iPrev` = `i`
    `smA`.add (0'i16, -1'i32, `i` .. `i`-1)
    while `i` > `limit`:
      bwFastRuneAt(`text`, `i`, `c`)
      `submatchStmt`
      if `smA`.len == 0:
        break
      if `smA`[0].ni == `eoeLit`:
        break
      `iPrev` = `i`
      `cPrev` = `c`.int32
    if `i` > 0:
      bwFastRuneAt(`text`, `i`, `c`)
    else:
      `c` = Rune(-1)
    `submatchEoeStmt`
    `i` = -1
    for n, capt, bounds in items `smA`:
      if n == `eoeLit`:
        `i` = bounds.a
        break

func findSomeOptImpl(
  text, ms, i: NimNode,
  regex: Regex
): NimNode =
  doAssert regex.litOpt.nfa.len > 0
  defVars limit
  let matchPrefixStmt = matchPrefixImpl(
    text, ms, i, limit, regex)
  let isOpt = quote do: true
  let findSomeStmt = findSomeImpl(
    text, ms, i, isOpt, regex)
  let regexLenLit = newLit max(
    regex.litOpt.nfa.len,
    regex.nfa.len)
  let charLit = newLit regex.litOpt.lit.char
  result = quote do:
    initMaybeImpl(`ms`, `regexLenLit`)
    `ms`.clear()
    var `limit` = `i`
    var i2 = -1
    while `i` < len(`text`):
      doAssert `i` > i2; i2 = `i`
      let litIdx = find(`text`, `charLit`, `i`)
      if litIdx == -1:
        break
      doAssert litIdx >= `i`
      `i` = litIdx
      `matchPrefixStmt`
      if `i` == -1:
        `i` = litIdx+1
      else:
        doAssert `i` <= litIdx
        `findSomeStmt`
        if hasMatches(`ms`):
          break
        if `i` == -1:
          break
    if not hasMatches(`ms`):
      `i` = -1

when defined(noRegexOpt):
  template findSomeOptTpl(txt, ms, i, regex): untyped =
    let isOpt = quote do: false
    findSomeImpl(txt, ms, i, isOpt, regex)
else:
  template findSomeOptTpl(txt, ms, i, regex): untyped =
    if regex.litOpt.nfa.len > 0:
      findSomeOptImpl(txt, ms, i, regex)
    else:
      let isOpt = quote do: false
      findSomeImpl(txt, ms, i, isOpt, regex)

# XXX declare text as const if it's a lit
proc findAllItImpl*(fr: NimNode): NimNode =
  expectKind fr, nnkForStmt
  if fr.len != 3:
    error "expected <for x in call(string, RegexLit): stmt>", fr
  let x = fr[0]
  if x.kind != nnkIdent:
    error "expected an identifier as for-loop variable", x
  if fr[1].len != 3:
    error "expected <string, RegexLit> parameters", fr
  let txt = fr[1][1]
  let exp = fr[1][2]
  # XXX can txt be checked somehow?
  if not (exp.kind == nnkCallStrLit and $exp[0] == "rex"):
    error "second parameter must be a <RegexLit>; ex: rex\"regex\"", exp
  var body = fr[2]
  if body.kind != nnkStmtList:
    body = newTree(nnkStmtList, body)
  defVars ms, i
  let regex = reCt(exp[1].strVal)
  let findSomeStmt = findSomeOptTpl(txt, ms, i, regex)
  result = quote do:
    block:
      var `x` = -1 .. 0
      var `i` = 0
      var i2 = -1
      var mi = 0
      var `ms`: RegexMatches
      while `i` <= len(`txt`):
        doAssert(`i` > i2); i2 = `i`
        `findSomeStmt`
        #debugEcho `i`
        if `i` < 0: break
        mi = 0
        while mi < len(`ms`):
          `x` = `ms`.m.s[mi].bounds
          `body`
          mi += 1
        if mi < len(`ms`): break
        if `i` == len(`txt`): break