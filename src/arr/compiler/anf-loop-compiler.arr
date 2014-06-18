#lang pyret

provide *
import ast as A
import sets as Sets
import "compiler/ast-anf.arr" as N
import "compiler/js-ast.arr" as J
import "compiler/gensym.arr" as G
import "compiler/compile-structs.arr" as CS
import "compiler/concat-lists.arr" as CL
import string-dict as D
import srcloc as SL

type Loc = SL.Srcloc
type ConcatList = CL.ConcatList

concat-empty = CL.concat-empty
concat-singleton = CL.concat-singleton
concat-append = CL.concat-append
concat-cons = CL.concat-cons
concat-snoc = CL.concat-snoc
concat-foldl = CL.concat-foldl
concat-foldr = CL.concat-foldr

fun type-name(str):
  "$type$" + str
end

j-fun = J.j-fun
j-var = J.j-var
j-id = J.j-id
j-method = J.j-method
j-block = J.j-block
j-true = J.j-true
j-false = J.j-false
j-num = J.j-num
j-str = J.j-str
j-return = J.j-return
j-assign = J.j-assign
j-if = J.j-if
j-if1 = J.j-if1
j-app = J.j-app
j-list = J.j-list
j-obj = J.j-obj
j-dot = J.j-dot
j-bracket = J.j-bracket
j-field = J.j-field
j-dot-assign = J.j-dot-assign
j-bracket-assign = J.j-bracket-assign
j-try-catch = J.j-try-catch
j-throw = J.j-throw
j-expr = J.j-expr
j-binop = J.j-binop
j-eq = J.j-eq
j-neq = J.j-neq
j-unop = J.j-unop
j-decr = J.j-decr
j-incr = J.j-incr
j-not = J.j-not
j-ternary = J.j-ternary
j-null = J.j-null
j-parens = J.j-parens
j-switch = J.j-switch
j-case = J.j-case
j-default = J.j-default
j-label = J.j-label
j-break = J.j-break
j-while = J.j-while
make-label-sequence = J.make-label-sequence

get-field-loc = j-id("G")
throw-uninitialized = j-id("U")
source-name = j-id("M")
undefined = j-id("D")



js-id-of = block:
  var js-ids = D.string-dict()
  lam(id :: String):
    when not(is-string(id)): raise("js-id-of got non-string: " + torepr(id));
    if js-ids.has-key(id):
      js-ids.get(id)
    else:
      no-hyphens = string-replace(id, "-", "_DASH_")
      safe-id = G.make-name(no-hyphens)
      js-ids.set(id, safe-id)
      safe-id
    end
  end
end


fun mk-id(base :: String):
  t = A.global-names.make-atom(base)
  { id: t, id-s: js-id-of(t.tostring()), id-j: j-id(js-id-of(t.tostring())) }
end

fun compiler-name(id):
  G.make-name("$" + id)
end

fun obj-of-loc(l):
  j-list(false, [list: 
    j-id("M"),
    j-num(l.start-line),
    j-num(l.start-column),
    j-num(l.start-char),
    j-num(l.end-line),
    j-num(l.end-column),
    j-num(l.end-char)
  ])
end

fun get-field(obj :: J.JExpr, field :: J.JExpr, loc :: J.JExpr):
  j-app(get-field-loc, [list: obj, field, loc])
end

fun raise-id-exn(loc, name):
  j-app(throw-uninitialized, [list: loc, j-str(name)])
end

fun add-stack-frame(exn-id, loc):
  j-method(j-dot(j-id(exn-id), "pyretStack"), "push", [list: loc])
end

fun rt-field(name): j-dot(j-id("R"), name);
fun rt-method(name, args): j-method(j-id("R"), name, args);

fun app(l, f, args):
  j-method(f, "app", args)
end

fun check-fun(l, f):
  j-if1(j-unop(j-parens(rt-method("isFunction", [list: f])), j-not),
    j-block([list: j-expr(j-method(rt-field("ffi"), "throwNonFunApp", [list: l, f]))]))
end

fun thunk-app(block):
  j-app(j-parens(j-fun([list: ], block)), [list: ])
end

fun thunk-app-stmt(stmt):
  thunk-app(j-block([list: stmt]))
end


data CaseResults:
  | c-exp(exp :: J.JExpr, other-stmts :: List<J.JStmt>)
  | c-field(field :: J.JField, other-stmts :: List<J.JStmt>)
  | c-block(block :: J.JBlock, new-cases :: ConcatList<J.JCase>)
end

fun compile-ann(ann :: A.Ann, visitor) -> CaseResults:
  cases(A.Ann) ann:
    | a-name(_, n) => c-exp(j-id(js-id-of(n.tostring())), empty)
    | a-arrow(_, _, _, _) => c-exp(rt-field("Function"), empty)
    | a-method(_, _, _) => c-exp(rt-field("Method"), empty)
    | a-app(l, base, _) => compile-ann(base, visitor)
    | a-record(l, fields) =>
      names = j-list(false, fields.map(_.name).map(j-str))
      locs = j-list(false, fields.map(_.l).map(visitor.get-loc))
      anns = for fold(acc from {fields: empty, others: empty}, f from fields):
        compiled = compile-ann(f.ann, visitor)
        {
          fields: j-field(f.name, compiled.exp) ^ link(_, acc.fields),
          others: compiled.other-stmts.reverse() + acc.others
        }
      end
      c-exp(
        rt-method("makeRecordAnn", [list:
            names,
            locs,
            j-obj(anns.fields.reverse())
          ]),
        anns.others.reverse()
        )
    | a-pred(l, base, exp) =>
      name = cases(A.AExpr) exp:
        | s-id(_, id) => id.toname()
        | s-id-letrec(_, id, _) => id.toname()
      end
      expr-to-compile = cases(A.Expr) exp:
        | s-id(l2, id) => N.a-id(l2, id)
        | s-id-letrec(l2, id, ok) => N.a-id-letrec(l2, id, ok)
      end
      compiled-base = compile-ann(base, visitor)
      compiled-exp = expr-to-compile.visit(visitor)
      c-exp(
        rt-method("makePredAnn", [list: compiled-base.exp, compiled-exp.exp, j-str(name)]),
        compiled-base.other-stmts +
        compiled-exp.other-stmts
        )
    | a-dot(l, m, field) =>
      c-exp(
        rt-method("getDotAnn", [list:
            visitor.get-loc(l),
            j-str(m.toname()),
            j-id(js-id-of(m.tostring())),
            j-str(field)]),
        empty)
    | a-blank => c-exp(rt-field("Any"), empty)
    | a-any => c-exp(rt-field("Any"), empty)
  end
end

fun arity-check(loc-expr, arity :: Number):
  j-if1(j-binop(j-dot(j-id("arguments"), "length"), j-neq, j-num(arity)),
    j-block([list:
        j-expr(j-method(rt-field("ffi"), "throwArityErrorC",
            [list: loc-expr, j-num(arity), j-id("arguments")]))]))
end

local-bound-vars-visitor = {
  j-field(self, name, value): value.visit(self) end,
  j-parens(self, exp): exp.visit(self) end,
  j-unop(self, exp, op): exp.visit(self) end,
  j-binop(self, left, op, right): left.visit(self).union(right.visit(self)) end,
  j-fun(self, args, body): sets.empty-tree-set end,
  j-app(self, func, args): args.foldl(lam(arg, base): base.union(arg.visit(self)) end, func.visit(self)) end,
  j-method(self, obj, meth, args): sets.empty-tree-set end,
  j-ternary(self, test, consq, alt): test.visit(self).union(consq.visit(self)).union(alt.visit(self)) end,
  j-assign(self, name, rhs): rhs.visit(self) end,
  j-bracket-assign(self, obj, field, rhs): obj.visit(self).union(field.visit(self)).union(rhs.visit(self)) end,
  j-dot-assign(self, obj, name, rhs): obj.visit(self).union(rhs.visit(self)) end,
  j-dot(self, obj, name): obj.visit(self) end,
  j-bracket(self, obj, field): obj.visit(self).union(field.visit(self)) end,
  j-list(self, multi-line, elts):
    elts.foldl(lam(arg, base): base.union(arg.visit(self)) end, sets.empty-tree-set)
  end,
  j-obj(self, fields): fields.foldl(lam(f, base): base.union(f.visit(self)) end, sets.empty-tree-set) end,
  j-id(self, id): sets.empty-tree-set end,
  j-str(self, s): sets.empty-tree-set end,
  j-num(self, n): sets.empty-tree-set end,
  j-true(self): sets.empty-tree-set end,
  j-false(self): sets.empty-tree-set end,
  j-null(self): sets.empty-tree-set end,
  j-undefined(self): sets.empty-tree-set end,
  j-label(self, label): sets.empty-tree-set end,
  j-case(self, exp, body): exp.visit(self).union(body.visit(self)) end,
  j-default(self, body): body.visit(self) end,
  j-block(self, stmts): stmts.foldl(lam(s, base): base.union(s.visit(self)) end, sets.empty-tree-set) end,
  j-var(self, name, rhs): [tree-set: name].union(rhs.visit(self)) end,
  j-if1(self, cond, consq): cond.visit(self).union(consq.visit(self)) end,
  j-if(self, cond, consq, alt): cond.visit(self).union(consq.visit(self)).union(alt.visit(self)) end,
  j-return(self, exp): exp.visit(self) end,
  j-try-catch(self, body, exn, catch): body.visit(self).union(catch.visit(self)) end,
  j-throw(self, exp): exp.visit(self) end,
  j-expr(self, exp): exp.visit(self) end,
  j-break(self): sets.empty-tree-set end,
  j-continue(self): sets.empty-tree-set end,
  j-switch(self, exp, branches):
    branches.foldl(lam(b, base): base.union(b.visit(self)) end, exp.visit(self))
  end,
  j-while(self, cond, body): cond.visit(self).union(body.visit(self)) end
}


fun compile-fun-body(l :: Loc, step :: String, fun-name :: String, compiler, args :: List<N.ABind>, arity :: Number, body :: N.AExpr) -> J.JBlock:
  make-label = make-label-sequence(0)
  ret-label = make-label()
  ans = js-id-of(compiler-name("ans"))
  apploc = js-id-of(compiler-name("al"))
  local-compiler = compiler.{make-label: make-label, cur-target: ret-label, cur-step: step, cur-ans: ans, cur-apploc: apploc}
  visited-body = body.visit(local-compiler)
  checker =
    j-block([list:
        arity-check(local-compiler.get-loc(l), arity)])
  ann-cases = compile-anns(local-compiler, step, args, local-compiler.make-label())
  switch-cases =
    concat-empty
  ^ concat-append(_, ann-cases.new-cases)
  ^ concat-snoc(_, j-case(ann-cases.new-label, visited-body.block))
  ^ concat-append(_, visited-body.new-cases)
  ^ concat-snoc(_, j-case(local-compiler.cur-target, j-block([list:
          j-expr(j-unop(rt-field("GAS"), j-incr)),
          j-return(j-id(local-compiler.cur-ans))])))
  ^ concat-snoc(_, j-default(j-block([list:
          j-throw(j-binop(j-binop(j-str("No case numbered "), J.j-plus, j-id(step)), J.j-plus,
              j-str(" in " + fun-name)))])))
  # Initialize the case numbers, for more legible output...
  switch-cases.each(lam(c): when J.is-j-case(c): c.exp.label.get() end end) 
  vars = (for concat-foldl(base from Sets.empty-tree-set, case-expr from switch-cases):
      base.union(case-expr.visit(local-bound-vars-visitor))
    end).to-list()
  act-record = rt-method("makeActivationRecord", [list:
      j-id(apploc),
      j-id(fun-name),
      j-id(step),
      j-list(false, args.map(lam(a): j-id(js-id-of(tostring(a.id))) end)),
      j-list(false, vars.map(lam(v): j-id(v) end))
    ])  
  e = js-id-of(compiler-name("e"))
  first-arg = js-id-of(tostring(args.first.id))
  ar = js-id-of(compiler-name("ar"))
  j-block([list:
      j-var(step, j-num(0)),
      j-var(local-compiler.cur-ans, undefined),
      j-var(apploc, local-compiler.get-loc(l)),
      j-try-catch(
        j-block([list:
            j-if(rt-method("isActivationRecord", [list: j-id(first-arg)]),
              j-block(
                [list:
                  j-var(ar, j-id(first-arg)),
                  j-expr(j-assign(step, j-dot(j-id(ar), "step"))),
                  j-expr(j-assign(apploc, j-dot(j-id(ar), "from"))),
                  j-expr(j-assign(local-compiler.cur-ans, j-dot(j-id(ar), "ans")))
                ] +
                for map_n(i from 0, arg from args):
                  j-expr(j-assign(js-id-of(tostring(arg.id)), j-bracket(j-dot(j-id(ar), "args"), j-num(i))))
                end +
                for map_n(i from 0, v from vars):
                  j-expr(j-assign(v, j-bracket(j-dot(j-id(ar), "vars"), j-num(i))))
                end),
              checker),
            j-if1(j-binop(j-unop(rt-field("GAS"), j-decr), J.j-leq, j-num(0)),
              j-block([list: j-expr(j-dot-assign(j-id("R"), "EXN_STACKHEIGHT", j-num(0))),
                  # j-expr(j-app(j-id("console.log"), [list: j-str("Out of gas in " + fun-name)])),
                  # j-expr(j-app(j-id("console.log"), [list: j-str("GAS is "), rt-field("GAS")])),
                  j-throw(rt-method("makeCont", empty))])),
            j-while(j-true,
              j-block([list:
                  # j-expr(j-app(j-id("console.log"), [list: j-str("In " + fun-name + ", step "), j-id(step), j-str(", GAS = "), rt-field("GAS"), j-str(", ans = "), j-id(local-compiler.cur-ans)])),
                  j-switch(j-id(step), switch-cases.to-list())]))]),
        e,
        j-block([list:
            j-if1(rt-method("isCont", [list: j-id(e)]),
              j-block([list: 
                  j-expr(j-bracket-assign(j-dot(j-id(e), "stack"),
                      j-unop(rt-field("EXN_STACKHEIGHT"), J.j-postincr), act-record))
                ])),
            j-if1(rt-method("isPyretException", [list: j-id(e)]),
              j-block([list: 
                  j-expr(add-stack-frame(e, local-compiler.get-loc(l)))
                ])),
            j-throw(j-id(e))]))
  ])
end

fun compile-anns(visitor, step, binds :: List<N.ABind>, entry-label):
  var cur-target = entry-label
  new-cases = for lists.fold(acc from concat-empty, b from binds):
    if A.is-a-blank(b.ann) or A.is-a-any(b.ann):
      acc
    else:
      compiled-ann = compile-ann(b.ann, visitor)
      new-label = visitor.make-label()
      new-case = j-case(cur-target,
        j-block(compiled-ann.other-stmts +
          [list:
            j-expr(j-assign(step, new-label)),
            j-expr(rt-method("_checkAnn",
              [list: visitor.get-loc(b.ann.l), compiled-ann.exp, j-id(js-id-of(b.id.tostring()))])),
            j-break]))
      cur-target := new-label
      concat-snoc(acc, new-case)
    end
  end
  { new-cases: new-cases, new-label: cur-target }
end

fun compile-split-app(l, compiler, opt-dest, f, args, opt-body):
  ans = compiler.cur-ans
  step = compiler.cur-step
  compiled-f = f.visit(compiler).exp
  compiled-args = args.map(lam(a): a.visit(compiler).exp end)
  var new-cases = concat-empty
  opt-visited-helper = opt-body.and-then(lam(b): some(b.visit(compiler)) end)
  helper-label =
    block:
      lbl = compiler.make-label()
      new-cases :=
        cases(Option) opt-dest:
          | some(dest) =>
            cases(Option) opt-visited-helper:
              | some(visited-helper) =>
                concat-cons(
                  j-case(lbl, j-block(
                      j-var(js-id-of(dest.tostring()), j-id(ans))
                      ^ link(_, visited-helper.block.stmts))),
                  visited-helper.new-cases)
              | none => raise("Impossible: compile-split-app can't have a dest without a body")
            end
          | none =>
            cases(Option) opt-visited-helper:
              | some(visited-helper) =>
                concat-cons(j-case(lbl, visited-helper.block), visited-helper.new-cases)
              | none => concat-empty
            end
        end
      lbl
    end
  c-block(
    j-block([list:
        check-fun(compiler.get-loc(l), compiled-f),
        # Update step before the call, so that if it runs out of gas, the resumer goes to the right step
        j-expr(j-assign(step,  helper-label)),
        j-expr(j-assign(compiler.cur-apploc, compiler.get-loc(l))),
        j-expr(j-assign(ans, app(compiler.get-loc(l), compiled-f, compiled-args))),
        j-break]),
    new-cases)
end

fun compile-split-if(compiler, opt-dest, cond, consq, alt, opt-body):
  consq-label = compiler.make-label()
  alt-label = compiler.make-label()
  after-if-label = compiler.make-label()
  ans = compiler.cur-ans
  opt-compiled-body = opt-body.and-then(lam(b): some(b.visit(compiler)) end)
  compiler-after-if = compiler.{cur-target: after-if-label}
  compiled-consq = consq.visit(compiler-after-if)
  compiled-alt = alt.visit(compiler-after-if)
  new-cases =
    concat-cons(j-case(consq-label, compiled-consq.block), compiled-consq.new-cases)
    + concat-cons(j-case(alt-label, compiled-alt.block), compiled-alt.new-cases)
    + (cases(Option) opt-dest:
      | some(dest) =>
        cases(Option) opt-compiled-body:
          | some(compiled-body) =>
            concat-cons(j-case(after-if-label,
                j-block(
                  j-var(js-id-of(dest.tostring()), j-id(ans))
                  ^ link(_, compiled-body.block.stmts))), compiled-body.new-cases)
          | none => raise("Impossible: compile-split-if can't have a dest without a body")
        end
      | none =>
        cases(Option) opt-compiled-body:
          | some(compiled-body) =>
            concat-cons(j-case(after-if-label, compiled-body.block), compiled-body.new-cases)
          | none => concat-empty
        end
    end)
  c-block(
    j-block([list: 
        j-if(rt-method("isPyretTrue", [list: cond.visit(compiler).exp]),
          j-block([list: j-expr(j-assign(compiler.cur-step, consq-label)), j-break]),
          j-block([list: j-expr(j-assign(compiler.cur-step, alt-label)), j-break]))
      ]),
    new-cases)
end
fun compile-cases-branch(compiler, compiled-val, branch :: N.ACasesBranch):
  compiled-body = branch.body.visit(compiler)
  branch-args = mk-id(branch.name)
  bind-args = for map_n(i from 0, arg from branch.args):
    j-var(js-id-of(arg.id.tostring()), j-bracket(branch-args.id-j, j-num(i)))
  end
  ann-cases = compile-anns(compiler, compiler.cur-step, branch.args, compiler.make-label())
  l = compiler.get-loc(branch.l)
  given-arity = j-num(branch.args.length())
  expected-arity = j-dot(branch-args.id-j, "length")
  checker = j-if1(j-binop(given-arity, j-neq, expected-arity),
    j-block([list:
        j-expr(j-method(rt-field("ffi"), "throwCasesArityErrorC",
            [list: l, given-arity, branch-args.id-j]))]))

  if CL.is-concat-empty(ann-cases.new-cases):
    c-block(
      j-block(
        (j-var(branch-args.id-s, j-app(j-dot(compiled-val, "$fields"), empty))
          ^ link(_, checker
            ^ link(_, bind-args)))
          + compiled-body.block.stmts),
      compiled-body.new-cases)
  else:
    first-label = ann-cases.new-cases.getFirst().exp
    c-block(
      j-block(
        (j-var(branch-args.id-s, j-app(j-dot(compiled-val, "$fields"), empty))
          ^ link(_, checker
            ^ link(_, bind-args)))
          + [list: j-expr(j-assign(compiler.cur-step, first-label)), j-break]),
      ann-cases.new-cases
      ^ concat-snoc(_, j-case(ann-cases.new-label, compiled-body.block))
      ^ concat-append(_, compiled-body.new-cases))
  end
end
  
fun compile-split-cases(compiler, opt-dest, typ, val :: N.AVal, branches :: List<N.ACasesBranch>, _else :: N.AExpr, opt-body :: Option<N.AExpr>):
  compiled-val = val.visit(compiler).exp
  after-cases-label = compiler.make-label()
  compiler-after-cases = compiler.{cur-target: after-cases-label}
  opt-compiled-body = opt-body.and-then(lam(b): some(b.visit(compiler)) end)
  compiled-branches = branches.map(compile-cases-branch(compiler-after-cases, compiled-val, _))
  compiled-else = _else.visit(compiler-after-cases)
  branch-labels = branches.map(lam(_): compiler.make-label() end)
  else-label = compiler.make-label()
  branch-cases = for fold2(acc from concat-empty, label from branch-labels, branch from compiled-branches):
    acc
    ^ concat-snoc(_, j-case(label, branch.block))
    ^ concat-append(_, branch.new-cases)
  end
  branch-else-cases =
    (branch-cases
      ^ concat-snoc(_, j-case(else-label, compiled-else.block))
      ^ concat-append(_, compiled-else.new-cases))
  dispatch-table = j-obj(for map2(branch from branches, label from branch-labels): j-field(branch.name, label) end)
  dispatch = mk-id("cases_dispatch")
  # NOTE: Ignoring typ for the moment!
  new-cases =
    branch-else-cases
    + (cases(Option) opt-dest:
      | some(dest) =>
        cases(Option) opt-compiled-body:
          | some(compiled-body) =>
            concat-cons(j-case(after-cases-label,
                j-block(
                  j-var(js-id-of(dest.tostring()), j-id(compiler.cur-ans))
                  ^ link(_, compiled-body.block.stmts))), compiled-body.new-cases)
          | none => raise("Impossible: compile-split-cases can't have a dest without a body")
        end
      | none =>
        cases(Option) opt-compiled-body:
          | some(compiled-body) =>
            concat-cons(j-case(after-cases-label, compiled-body.block), compiled-body.new-cases)
          | none => concat-empty
        end
    end)
  c-block(
    j-block([list:
        j-var(dispatch.id-s, dispatch-table),
        j-expr(j-assign(compiler.cur-step,
            j-binop(j-bracket(dispatch.id-j, j-dot(compiled-val, "$name")), J.j-or, else-label))),
        j-break]),
    new-cases)
end
  
compiler-visitor = {
  a-module(self, l, answer, provides, types, checks):
    types-obj-fields = for fold(acc from {fields: empty, others: empty}, ann from types):
      compiled = compile-ann(ann.ann, self)
      {
        fields: j-field(ann.name, compiled.exp) ^ link(_, acc.fields),
        others: compiled.other-stmts.reverse() + acc.others
      }
    end

    compiled-provides = provides.visit(self)
    compiled-answer = answer.visit(self)
    compiled-checks = checks.visit(self)
    c-exp(
      rt-method("makeObject", [list:
          j-obj([list:
              j-field("answer", compiled-answer.exp),
              j-field("provide-plus-types",
                rt-method("makeObject", [list: j-obj([list:
                        j-field("values", compiled-provides.exp),
                        j-field("types", j-obj(types-obj-fields.fields.reverse()))
                    ])])),
              j-field("checks", compiled-checks.exp)])]),
      types-obj-fields.others
        + compiled-provides.other-stmts + compiled-answer.other-stmts + compiled-checks.other-stmts)
  end,
  a-type-let(self, l, bind, body):
    cases(N.ATypeBind) bind:
      | a-type-bind(l2, name, ann) =>
        visited-body = body.visit(self)
        compiled-ann = compile-ann(ann, self)
        c-block(
          j-block(
            compiled-ann.other-stmts +
            [list: j-var(js-id-of(name.tostring()), compiled-ann.exp)] +
            visited-body.block.stmts
            ),
          visited-body.new-cases)
      | a-newtype-bind(l2, name, nameb) =>
        brander-id = js-id-of(nameb.tostring())
        visited-body = body.visit(self)
        c-block(
          j-block(
            [list:
              j-var(brander-id, rt-method("namedBrander", [list: j-str(name.toname())])),
              j-var(js-id-of(name.tostring()), rt-method("makeBranderAnn", [list: j-id(brander-id), j-str(name.toname())]))
            ] +
            visited-body.block.stmts),
          visited-body.new-cases)
    end
  end,
  a-let(self, l :: Loc, b :: N.ABind, e :: N.ALettable, body :: N.AExpr):
    cases(N.ALettable) e:
      | a-app(l2, f, args) =>
        compile-split-app(l2, self, some(b.id), f, args, some(body))
      | a-if(l2, cond, then, els) =>
        compile-split-if(self, some(b.id), cond, then, els, some(body))
      | a-cases(l2, typ, val, branches, _else) =>
        compile-split-cases(self, some(b.id), typ, val, branches, _else, some(body))
      | else =>
        compiled-e = e.visit(self)
        compiled-body = body.visit(self)
        if A.is-a-blank(b.ann) or A.is-a-any(b.ann):
          c-block(
            j-block(
              compiled-e.other-stmts +
              link(
                j-var(js-id-of(b.id.tostring()), compiled-e.exp),
                compiled-body.block.stmts
                )
              ),
            compiled-body.new-cases
            )
        else:
          step = self.cur-step
          after-ann = self.make-label()
          after-ann-case = j-case(after-ann, j-block(compiled-body.block.stmts))
          compiled-ann = compile-ann(b.ann, self)
          c-block(
            j-block(
              compiled-e.other-stmts +
              compiled-ann.other-stmts +
              [list:
                j-var(js-id-of(b.id.tostring()), compiled-e.exp),
                j-expr(j-assign(step, after-ann)),
                j-expr(rt-method("_checkAnn", [list:
                      self.get-loc(b.ann.l),
                      compiled-ann.exp,
                      j-id(js-id-of(b.id.tostring()))])),
                j-break
              ]),
            concat-cons(after-ann-case, compiled-body.new-cases))
        end
    end
  end,
  a-var(self, l :: Loc, b :: N.ABind, e :: N.ALettable, body :: N.AExpr):
    compiled-body = body.visit(self)
    compiled-e = e.visit(self)
    # TODO: annotations here?
    c-block(
      j-block(
        j-var(js-id-of(b.id.tostring()),
          j-obj([list: j-field("$var", compiled-e.exp), j-field("$name", j-str(b.id.toname()))]))
        ^ link(_, compiled-body.block.stmts)),
      compiled-body.new-cases)
  end,
  a-seq(self, l, e1, e2):
    cases(N.ALettable) e1:
      | a-app(l2, f, args) =>
        compile-split-app(l2, self, none, f, args, some(e2))
      | a-if(l2, cond, consq, alt) =>
        compile-split-if(self, none, cond, consq, alt, some(e2))
      | a-cases(l2, typ, val, branches, _else) =>
        compile-split-cases(self, none, typ, val, branches, _else, some(e2))
      | else =>
        e1-visit = e1.visit(self).exp
        e2-visit = e2.visit(self)
        if J.JStmt(e1-visit):
          c-block(
            j-block(link(e1-visit, e2-visit.block.stmts)),
            e2-visit.new-cases)
        else:
          c-block(
            j-block(link(j-expr(e1-visit), e2-visit.block.stmts)),
            e2-visit.new-cases)
        end
    end
  end,
  a-if(self, l :: Loc, cond :: N.AVal, consq :: N.AExpr, alt :: N.AExpr):
    raise("Impossible: a-if directly in compiler-visitor should never happen")
  end,
  a-cases(self, l :: Loc, typ :: A.Ann, val :: N.AVal, branches :: List<N.ACasesBranch>, _else :: N.AExpr):
    raise("Impossible: a-cases directly in compiler-visitor should never happen")
  end,
  a-lettable(self, e :: N.ALettable): # Need to add back the location field
    cases(N.ALettable) e:
      | a-app(l, f, args) =>
        compile-split-app(l, self, none, f, args, none)
      | a-if(l, cond, consq, alt) =>
        compile-split-if(self, none, cond, consq, alt, none)
      | a-cases(l, typ, val, branches, _else) =>
        compile-split-cases(self, none, typ, val, branches, _else, none)
      | else =>
         visit-e = e.visit(self)
         c-block(
           j-block(
             j-expr(j-assign(self.cur-step, self.cur-target))
             ^ link(_, visit-e.other-stmts
                 + [list:
                 j-expr(j-assign(self.cur-ans, visit-e.exp)),
                 j-break])),
           concat-empty)
    end
  end,
  a-assign(self, l :: Loc, id :: A.Name, value :: N.AVal):
    visit-value = value.visit(self)
    c-exp(j-dot-assign(j-id(js-id-of(id.tostring())), "$var", visit-value.exp), visit-value.other-stmts)
  end,
  a-app(self, l :: Loc, f :: N.AVal, args :: List<N.AVal>):
    raise("Impossible: a-app directly in compiler-visitor should never happen")
  end,
  a-prim-app(self, l :: Loc, f :: String, args :: List<N.AVal>):
    visit-args = args.map(_.visit(self))
    set-loc = [list:
      j-expr(j-assign(self.cur-apploc, self.get-loc(l)))
    ]
    other-stmts = visit-args.foldr(lam(va, acc): va.other-stmts + acc end, set-loc)
    c-exp(rt-method(f, visit-args.map(_.exp)), other-stmts)
  end,
  
  a-obj(self, l :: Loc, fields :: List<N.AField>):
    visit-fields = fields.map(lam(f): f.visit(self) end)
    other-stmts = visit-fields.foldr(lam(vf, acc): vf.other-stmts + acc end, empty)
    c-exp(rt-method("makeObject", [list: j-obj(visit-fields.map(_.field))]), other-stmts)
  end,
  a-extend(self, l :: Loc, obj :: N.AVal, fields :: List<N.AField>):
    visit-obj = obj.visit(self)
    visit-fields = fields.map(lam(f): f.visit(self) end)
    other-stmts = visit-fields.foldr(lam(vf, acc): vf.other-stmts + acc end, visit-obj.other-stmts)
    c-exp(j-method(visit-obj.exp, "extendWith", [list: j-obj(visit-fields.map(_.field))]),
      other-stmts)
  end,
  a-dot(self, l :: Loc, obj :: N.AVal, field :: String):
    visit-obj = obj.visit(self)
    c-exp(get-field(visit-obj.exp, j-str(field), self.get-loc(l)), visit-obj.other-stmts)
  end,
  a-colon(self, l :: Loc, obj :: N.AVal, field :: String):
    visit-obj = obj.visit(self)
    c-exp(rt-method("getColonField", [list: visit-obj.exp, j-str(field)]), visit-obj.other-stmts)
  end,
  a-lam(self, l :: Loc, args :: List<N.ABind>, ret :: A.Ann, body :: N.AExpr):
    new-step = js-id-of(compiler-name("step"))
    temp = js-id-of(compiler-name("temp_lam"))
    # NOTE: args may be empty, so we need at least one name ("resumer") for the stack convention
    effective-args =
      if args.length() > 0: args
      else: [list: N.a-bind(l, A.s-name(l, compiler-name("resumer")), A.a-blank)]
      end
    c-exp(
      rt-method("makeFunction", [list: j-id(temp)]),
      [list:
        j-var(temp,
          j-fun(effective-args.map(_.id).map(_.tostring()).map(js-id-of),
                compile-fun-body(l, new-step, temp, self, effective-args, args.length(), body)))])
  end,
  a-method(self, l :: Loc, args :: List<N.ABind>, ret :: A.Ann, body :: N.AExpr):
    # step-method = js-id-of(compiler-name("step"))
    # temp-method = compiler-name("temp_method")
    # compiled-body-method = compile-fun-body(l, step-method, temp-method, self, args, args.length() - 1, body)
    # method-var = j-var(temp-method,
    #   j-fun(args.map(lam(a): js-id-of(a.id.tostring()) end), compiled-body-method))
    step-curry = js-id-of(compiler-name("step"))
    temp-curry = js-id-of(compiler-name("temp_curry"))
    # NOTE: excluding self, args may be empty, so we need at least one name ("resumer") for the stack convention
    effective-curry-args =
      if args.length() > 1: args.rest
      else: [list: N.a-bind(l, A.s-name(l, compiler-name("resumer")), A.a-blank)]
      end
    compiled-body-curry =
      compile-fun-body(l, step-curry, temp-curry, self, effective-curry-args, args.length() - 1, body)
    curry-var = j-var(temp-curry,
      j-fun(effective-curry-args.map(lam(a): js-id-of(a.id.tostring()) end), compiled-body-curry))
    #### TODO!
    c-exp(
      rt-method("makeMethod", [list: j-fun([list: js-id-of(args.first.id.tostring())],
            j-block([list: curry-var, j-return(j-id(temp-curry))])),
          j-obj([list: j-field("length", j-num(args.length()))])]),
      empty)
  end,
  a-val(self, v :: N.AVal):
    v.visit(self)
  end,
  a-field(self, l :: Loc, name :: String, value :: N.AVal):
    visit-v = value.visit(self)
    c-field(j-field(name, visit-v.exp), visit-v.other-stmts)
  end,
  a-array(self, l, values):
    visit-vals = values.map(_.visit(self))
    other-stmts = visit-vals.foldr(lam(v, acc): v.other-stmts + acc end, empty)
    c-exp(j-list(false, visit-vals.map(_.exp)), other-stmts)
  end,
  a-srcloc(self, l, loc):
    c-exp(self.get-loc(loc), empty)
  end,
  a-num(self, l :: Loc, n :: Number):
    if num-is-fixnum(n):
      c-exp(j-parens(j-num(n)), empty)
    else:
      c-exp(rt-method("makeNumberFromString", [list: j-str(tostring(n))]), empty)
    end
  end,
  a-str(self, l :: Loc, s :: String):
    c-exp(j-parens(j-str(s)), empty)
  end,
  a-bool(self, l :: Loc, b :: Boolean):
    c-exp(j-parens(if b: j-true else: j-false end), empty)
  end,
  a-undefined(self, l :: Loc):
    c-exp(undefined, empty)
  end,
  a-id(self, l :: Loc, id :: A.Name):
    c-exp(j-id(js-id-of(id.tostring())), empty)
  end,
  a-id-var(self, l :: Loc, id :: A.Name):
    c-exp(j-dot(j-id(js-id-of(id.tostring())), "$var"), empty)
  end,
  a-id-letrec(self, l :: Loc, id :: A.Name, safe :: Boolean):
    s = id.tostring()
    if safe:
      c-exp(j-dot(j-id(js-id-of(s)), "$var"), empty)
    else:
      c-exp(
        j-ternary(
          j-binop(j-dot(j-id(js-id-of(s)), "$var"), j-eq, undefined),
          raise-id-exn(self.get-loc(l), id.toname()),
          j-dot(j-id(js-id-of(s)), "$var")),
        empty)
    end
  end,

  a-data-expr(self, l, name, namet, variants, shared):
    fun brand-name(base):
      compiler-name("brand-" + base)
    end

    visit-shared-fields = shared.map(_.visit(self))
    shared-fields = visit-shared-fields.map(_.field)
    shared-stmts = visit-shared-fields.foldr(lam(vf, acc): vf.other-stmts + acc end, empty)
    external-brand = j-id(js-id-of(namet.tostring()))

    fun make-brand-predicate(loc :: Loc, b :: J.JExpr, pred-name :: String):
      j-field(
        pred-name,
        rt-method("makeFunction", [list: 
            j-fun(
              [list: "val"],
              j-block([list:
                  arity-check(self.get-loc(loc), 1),
                  j-return(rt-method("makeBoolean", [list: rt-method("hasBrand", [list: j-id("val"), b])]))
                ])
              )
          ])
        )
    end

    fun make-variant-constructor(l2, base-id, brands-id, vname, members, refl-name, refl-fields):
      member-names = members.map(lam(m): m.bind.id.toname();)
      member-ids = members.map(lam(m): m.bind.id.tostring();)

      constr-body = [list:
        j-var("dict", rt-method("create", [list: j-id(base-id)]))
      ] +
      for map3(n from member-names, m from members, id from member-ids):
        cases(N.AMemberType) m.member-type:
          | a-normal => j-expr(j-bracket-assign(j-id("dict"), j-str(n), j-id(js-id-of(id))))
          | a-cyclic => raise("Cannot handle cyclic fields yet")
          | a-mutable => raise("Cannot handle mutable fields yet")
        end
      end +
      [list: 
        j-return(rt-method("makeDataValue", [list: j-id("dict"), j-id(brands-id), refl-name, refl-fields]))
      ]

      nonblank-anns = for filter(m from members):
        not(A.is-a-blank(m.bind.ann)) and not(A.is-a-any(m.bind.ann))
      end
      compiled-anns = for fold(acc from {anns: empty, others: empty}, m from nonblank-anns):
        compiled = compile-ann(m.bind.ann, self)
        {
          anns: compiled.exp ^ link(_, acc.anns),
          others: compiled.other-stmts.reverse() + acc.others
        }
      end
      compiled-locs = for map(m from nonblank-anns): self.get-loc(m.bind.ann.l) end
      compiled-vals = for map(m from nonblank-anns): j-id(js-id-of(m.bind.id.tostring())) end
      
      # NOTE(joe 6-14-2014): We cannot currently statically check for if an annotation
      # is a refinement because of type aliases.  So, we use checkAnnArgs, which takes
      # a continuation and manages all of the stack safety of annotation checking itself.
      c-exp(
        rt-method("makeFunction", [list:
            j-fun(
              member-ids.map(js-id-of),
              j-block(
                [list:
                  arity-check(self.get-loc(l2), member-names.length())
                ] +
                compiled-anns.others.reverse() +
                [list:
                  j-return(rt-method("checkAnnArgs", [list:
                        j-list(false, compiled-anns.anns.reverse()),
                        j-list(false, compiled-vals),
                        j-list(false, compiled-locs),
                        j-fun(empty, j-block(constr-body))
                      ]))
              ]))]),
        empty)
    end

    fun compile-variant(v :: N.AVariant):
      vname = v.name
      variant-base-id = js-id-of(compiler-name(vname + "-base"))
      variant-brand = brand-name(vname)
      variant-brand-obj-id = js-id-of(compiler-name(vname + "-brands"))
      variant-brands = j-obj([list: 
          j-field(variant-brand, j-true)
        ])
      visit-with-fields = v.with-members.map(_.visit(self))

      refl-name = j-str(vname)
      refl-fields =
        cases(N.AVariant) v:
          | a-variant(_, _, _, members, _) =>
            j-fun(empty, j-block([list: j-return(j-list(false,
                      members.map(lam(m):
                          get-field(j-id("this"), j-str(m.bind.id.toname()), self.get-loc(m.l))
                        end)))]))
          | a-singleton-variant(_, _, _) =>
            j-fun(empty, j-block([list: j-return(j-list(false, empty))]))
        end
      
      stmts =
        visit-with-fields.foldr(lam(vf, acc): vf.other-stmts + acc end,
          [list: 
            j-var(variant-base-id, j-obj(shared-fields + visit-with-fields.map(_.field))),
            j-var(variant-brand-obj-id, variant-brands),
            j-expr(j-bracket-assign(
              j-id(variant-brand-obj-id),
              j-dot(external-brand, "_brand"),
              j-true))
        ])
      predicate = make-brand-predicate(v.l, j-str(variant-brand), A.make-checker-name(vname))

      cases(N.AVariant) v:
        | a-variant(l2, constr-loc, _, members, with-members) =>
          constr-vname = js-id-of(vname)
          compiled-constr =
            make-variant-constructor(constr-loc, variant-base-id, variant-brand-obj-id, constr-vname, members,
              refl-name, refl-fields)
          {
            stmts: stmts + compiled-constr.other-stmts + [list: j-var(constr-vname, compiled-constr.exp)],
            constructor: j-field(vname, j-id(constr-vname)),
            predicate: predicate
          }
        | a-singleton-variant(_, _, with-members) =>
          {
            stmts: stmts,
            constructor: j-field(vname, rt-method("makeDataValue", [list: j-id(variant-base-id), j-id(variant-brand-obj-id), refl-name, refl-fields])),
            predicate: predicate
          }
      end
    end

    variant-pieces = variants.map(compile-variant)

    header-stmts = for fold(acc from [list: ], piece from variant-pieces):
      piece.stmts.reverse() + acc
    end.reverse()
    obj-fields = for fold(acc from [list: ], piece from variant-pieces):
      [list: piece.constructor] + [list: piece.predicate] + acc
    end.reverse()

    data-predicate = make-brand-predicate(l, j-dot(external-brand, "_brand"), name)

    data-object = rt-method("makeObject", [list: j-obj([list: data-predicate] + obj-fields)])

    c-exp(data-object, shared-stmts + header-stmts)
  end
}

remove-useless-if-visitor = N.default-map-visitor.{
  a-if(self, l, c, t, e):
    cases(N.AVal) c:
      | a-bool(_, test) =>
        if test:
          visit-t = t.visit(self)
          if N.is-a-lettable(visit-t): visit-t.e else: N.a-if(l, c.visit(self), visit-t, e.visit(self)) end
        else:
          visit-e = e.visit(self)
          if N.is-a-lettable(visit-e): visit-e.e else: N.a-if(l, c.visit(self), t.visit(self), visit-e) end
        end
      | else => N.a-if(l, c.visit(self), t.visit(self), e.visit(self))
    end
  end
}

check:
  d = N.dummy-loc
  true1 = N.a-if(d, N.a-bool(d, true),
    N.a-lettable(N.a-val(N.a-num(d, 1))),
    N.a-lettable(N.a-val(N.a-num(d, 2))))
  true1.visit(remove-useless-if-visitor) is N.a-val(N.a-num(d, 1))

  false4 = N.a-if(d, N.a-bool(d, false),
    N.a-lettable(N.a-val(N.a-num(d, 3))),
    N.a-lettable(N.a-val(N.a-num(d, 4))))
  false4.visit(remove-useless-if-visitor) is N.a-val(N.a-num(d, 4))

  N.a-if(d, N.a-id(d, A.s-name(d, "x")), N.a-lettable(true1), N.a-lettable(false4)
    ).visit(remove-useless-if-visitor)
    is N.a-if(d, N.a-id(d, A.s-name(d, "x")),
    N.a-lettable(N.a-val(N.a-num(d, 1))),
    N.a-lettable(N.a-val(N.a-num(d, 4))))
  
end

fun mk-abbrevs(l):
  [list: 
    j-var("G", rt-field("getFieldLoc")),
    j-var("U", j-fun([list: "loc", "name"],
        j-block([list: j-method(rt-field("ffi"), "throwUninitializedIdMkLoc",
                          [list: j-id("loc"), j-id("name")])]))),
    j-var("M", j-str(l.source)),
    j-var("D", rt-field("undefined"))
  ]
end


fun compile-program(self, l, imports, prog, freevars, env):
  fun inst(id): j-app(j-id(id), [list: j-id("R"), j-id("NAMESPACE")]);
  free-ids = freevars.difference(sets.list-to-tree-set(imports.map(_.name))).difference(sets.list-to-tree-set(imports.map(_.types)))
  namespace-binds = for map(n from free-ids.to-list()):
    bind-name = cases(A.Name) n:
      | s-global(s) => n.toname()
      | s-type-global(s) => type-name(n.toname())
    end
    j-var(js-id-of(n.tostring()), j-method(j-id("NAMESPACE"), "get", [list: j-str(bind-name)]))
  end
  ids = imports.map(_.name).map(_.tostring()).map(js-id-of)
  type-imports = imports.filter(N.is-a-import-types)
  type-ids = type-imports.map(_.types).map(_.tostring()).map(js-id-of)
  filenames = imports.map(lam(i):
      cases(N.AImportType) i.import-type:
        | a-import-builtin(_, name) => "trove/" + name
        | a-import-file(_, file) => file
      end
    end)
  module-id = compiler-name(l.source)
  module-ref = lam(name): j-bracket(rt-field("modules"), j-str(name));
  input-ids = ids.map(lam(f): compiler-name(f) end)
  fun wrap-modules(modules, body-name, body-fun):
    mod-input-names = modules.map(_.input-id)
    mod-input-ids = mod-input-names.map(j-id)
    mod-val-ids = modules.map(_.id)
    j-return(rt-method("loadModulesNew",
        [list: j-id("NAMESPACE"), j-list(false, mod-input-ids),
          j-fun(mod-input-names,
            j-block(
              for map2(m from mod-val-ids, in from mod-input-ids):
                j-var(m, rt-method("getField", [list: in, j-str("values")]))
              end +
              for map2(mt from type-ids, in from mod-input-ids):
                j-var(mt, rt-method("getField", [list: in, j-str("types")]))
              end +
              [list: 
                j-var(body-name, body-fun),
                j-return(rt-method(
                    "safeCall", [list: 
                      j-id(body-name),
                      j-fun([list: "moduleVal"],
                        j-block([list: 
                            j-expr(j-bracket-assign(rt-field("modules"), j-str(module-id), j-id("moduleVal"))),
                            j-return(j-id("moduleVal"))
                    ]))]))]))]))
  end
  module-specs = for map2(id from ids, in-id from input-ids):
    { id: id, input-id: in-id }
  end
  var locations = concat-empty
  var loc-count = 0
  var loc-cache = D.string-dict()
  locs = "L"
  fun get-loc(shadow l :: Loc):
    as-str = torepr(l)
    if loc-cache.has-key(as-str):
      loc-cache.get(as-str)
    else:
      ans = j-bracket(j-id(locs), j-num(loc-count))
      loc-cache.set(as-str, ans)
      loc-count := loc-count + 1
      locations := concat-snoc(locations, obj-of-loc(l))
      ans
    end
  end

  step = js-id-of(compiler-name("step"))
  toplevel-name = js-id-of(compiler-name("toplevel"))
  apploc = js-id-of(compiler-name("al"))
  resumer = N.a-bind(l, A.s-name(l, compiler-name("resumer")), A.a-blank)
  visited-body = compile-fun-body(l, step, toplevel-name, self.{get-loc: get-loc, cur-apploc: apploc}, [list: resumer], 0, prog)
  toplevel-fun = j-fun([list: js-id-of(tostring(resumer.id))], visited-body)
  define-locations = j-var(locs, j-list(true, locations.to-list()))
  j-app(j-id("define"), [list: j-list(true, filenames.map(j-str)), j-fun(input-ids, j-block([list: 
            j-return(j-fun([list: "R", "NAMESPACE"],
                j-block([list: 
                    j-if(module-ref(module-id),
                      j-block([list: j-return(module-ref(module-id))]),
                      j-block(mk-abbrevs(l) +
                        [list: define-locations] + 
                        namespace-binds +
                        [list: wrap-modules(module-specs, toplevel-name, toplevel-fun)]))])))]))])
end

fun non-splitting-compiler(env):
  compiler-visitor.{
    a-program(self, l, imports, body):
      simplified = body.visit(remove-useless-if-visitor)
      freevars = N.freevars-e(simplified)
      compile-program(self, l, imports, simplified, freevars, env)
    end
  }
end

splitting-compiler = non-splitting-compiler