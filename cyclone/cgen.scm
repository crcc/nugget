;;
;; Cyclone Scheme
;; Copyright (c) 2014, Justin Ethier
;; All rights reserved.
;;
;; This module compiles scheme code to a Cheney-on-the-MTA C runtime.
;;

(define (emit line)
  (display line)
  (newline))

(define (string-join lst delim)
  (cond
    ((null? lst) 
      "")
    ((= (length lst) 1) 
      (car lst))
    (else
      (string-append 
        (car lst) 
        delim 
        (string-join (cdr lst) delim)))))

;; Name-mangling.

;; We have to "mangle" Scheme identifiers into
;; C-compatible identifiers, because names like
;; foo-bar/baz are not identifiers in C.

; mangle : symbol -> string
(define (mangle symbol)
 (letrec
   ((m (lambda (chars)
      (if (null? chars)
        '()
        (if (or (and (char-alphabetic? (car chars)) (not (char=? (car chars) #\_)))
                (char-numeric? (car chars)))
            (cons (car chars) (m (cdr chars)))
            (cons #\_ (append (integer->char-list (char->natural (car chars)))
                              (m (cdr chars))))))))
    (ident (list->string (m (string->list (symbol->string symbol))))))
   (if (member (string->symbol ident) *c-keywords*)
     (string-append "_" ident)
     ident)))

(define *c-keywords* 
 '(auto _Bool break case char _Complex const continue default do double else
   enum extern float for goto if _Imaginary inline int long register restrict
   return short signed sizeof static struct switch typedef union unsigned
   void volatile while))

(define *c-main-function*
"main(int argc,char **argv)
{long stack_size = long_arg(argc,argv,\"-s\",STACK_SIZE);
 long heap_size = long_arg(argc,argv,\"-h\",HEAP_SIZE);
 global_stack_size = stack_size;
 global_heap_size = heap_size;
 main_main(stack_size,heap_size,(char *) &stack_size);
 return 0;}")

;;; Auto-generation of C macros
(define *c-call-arity* 0)

(define (set-c-call-arity! arity)
  (cond
    ((not (number? arity))
     (error `(Non-numeric number of arguments received ,arity)))
    (else
      (if (> arity *c-call-arity*)
          (set! *c-call-arity* arity)))))

(define (emit-c-macros)
  (emit (c-macro-after-longjmp))
  (emit-c-arity-macros 0))

(define (emit-c-arity-macros arity)
  (when (<= arity *c-call-arity*)
    (emit (c-macro-funcall arity))
    (emit (c-macro-return-funcall arity))
    (emit (c-macro-return-check arity))
    (emit-c-arity-macros (+ arity 1))))

(define (c-macro-after-longjmp)
  (letrec (
    (append-args
      (lambda (n)
        (if (> n 0)
          (string-append
            (append-args (- n 1))
            ",gc_ans[" (number->string (- n 1)) "]")
          "")))
    (append-next-clause
      (lambda (i)
         (cond 
           ((= i 0)
            (string-append
              "  if (gc_num_ans == 0) { \\\n"
              "    funcall0((closure) gc_cont); \\\n"
              (append-next-clause (+ i 1))))
           ((<= i *c-call-arity*)
            (let ((this-clause
                    (string-append
                      "  } else if (gc_num_ans == " (number->string i)") { \\\n"
                      "    funcall" (number->string i) "((closure) gc_cont" (append-args i) "); \\\n")))
               (string-append 
                  this-clause
                  (append-next-clause (+ i 1)))))
           (else
             "  } else { \\\n"
             "      printf(\"Unsupported number of args from GC %d\\n\", gc_num_ans); \\\n"
                    "  } \n")))))
  (string-append
    "#define AFTER_LONGJMP \\\n"
    (append-next-clause 0))))

(define (c-macro-return-funcall num-args)
  (let ((args (c-macro-n-prefix num-args ",a"))
        (n (number->string num-args))
        (arry-assign (c-macro-array-assign num-args "buf" "a")))
    (string-append
      "/* Return to continuation after checking for stack overflow. */\n"
      "#define return_funcall" n "(cfn" args ") \\\n"
      "{char stack; \\\n"
      " if (DEBUG_ALWAYS_GC || check_overflow(&stack,stack_limit1)) { \\\n"
      "     object buf[" n "]; " arry-assign "\\\n"
      "     GC(cfn,buf," n "); return; \\\n"
      " } else {funcall" n "((closure) (cfn)" args "); return;}}\n")))

(define (c-macro-return-check num-args)
  (let ((args (c-macro-n-prefix num-args ",a"))
        (n (number->string num-args))
        (arry-assign (c-macro-array-assign num-args "buf" "a")))
    (string-append
      "/* Evaluate an expression after checking for stack overflow. */\n"
      "#define return_check" n "(_fn" args ") { \\\n"
      " char stack; \\\n"
      " if (DEBUG_ALWAYS_GC || check_overflow(&stack,stack_limit1)) { \\\n"
      "     object buf[" n "]; " arry-assign " \\\n"
      "     mclosure0(c1, _fn); \\\n"
      "     GC(&c1, buf, " n "); return; \\\n"
      " } else { (_fn)((closure)_fn" args "); }}\n")))

(define (c-macro-funcall num-args)
  (let ((args (c-macro-n-prefix num-args ",a"))
        (n (number->string num-args)))
    (string-append
      "#define funcall" n "(cfn" args ") ((cfn)->fn)(cfn" args ")")))

(define (c-macro-n-prefix n prefix)
  (if (> n 0)
    (string-append
      (c-macro-n-prefix (- n 1) prefix)
      (string-append prefix (number->string n)))
    ""))

(define (c-macro-array-assign n prefix assign)
  (if (> n 0)
    (string-append
      (c-macro-array-assign (- n 1) prefix assign)
      prefix "[" (number->string (- n 1)) "] = " 
      assign (number->string n) ";")
    ""))

;;; Compilation routines.

;; Return generated code that also requests allocation of C variables on stack
(define (c-code/vars str cvars)
  (list str
        cvars))

;; Return generated code with no C variables allocated on the stack
(define (c-code str) (c-code/vars str (list)))

;; Append arg count to a C code pair
(define (c:tuple/args cp num-args)
  (append cp (list num-args)))

;; Functions to work with data structures that contain C code:
;;
;; body - The actual body of C code
;; allocs - Allocations made by C code, eg "int c"
;; num-args - Number of function arguments combined in the tuple (optional)
;;
(define (c:body c-pair) (car c-pair))
(define (c:allocs c-pair) (cadr c-pair))
(define (c:num-args c-tuple) (caddr c-tuple))

(define (c:allocs->str c-allocs . prefix)
  (apply
    string-append
    (map
        (lambda (c)
           (string-append 
            (if (null? prefix)
                ""
                (car prefix))
            c 
            "\n"))
        c-allocs)))

(define (c:append cp1 cp2)
  (c-code/vars 
    (string-append (c:body cp1) (c:body cp2))
    (append (c:allocs cp1) (c:allocs cp2))))

(define (c:append/prefix prefix cp1 cp2)
  (c-code/vars 
    (string-append prefix (c:body cp1) (c:body cp2))
    (append (c:allocs cp1) (c:allocs cp2))))

(define (c:serialize cp prefix)
    (string-append
        (c:allocs->str (c:allocs cp) prefix)
        prefix
        (c:body cp)))

;; c-compile-program : exp -> string
(define (c-compile-program exp)
  (let* ((preamble "")
         (append-preamble (lambda (s)
                            (set! preamble (string-append preamble "  " s "\n"))))
         (body (c-compile-exp exp append-preamble "cont")))
    (string-append 
     preamble 
     (c:serialize body "  ") ;" ;\n"
;     "int main (int argc, char* argv[]) {\n"
;     "  return 0;\n"
;     " }\n"
)))

;; c-compile-exp : exp (string -> void) -> string
;;
;; exp - expression to compiler
;; append-preamble - ??
;; cont - name of the next continuation
;;        this is experimental and probably needs refinement
(define (c-compile-exp exp append-preamble cont)
  (cond
    ; Core forms:
    ((const? exp)       (c-compile-const exp))
    ((prim?  exp)       (c-compile-prim exp))
    ((ref?   exp)       (c-compile-ref exp))
    ((quote? exp)       (c-compile-quote exp))
    ((if? exp)          (c-compile-if exp append-preamble cont))

    ; IR (2):
    ((tagged-list? '%closure exp)
     (c-compile-closure exp append-preamble cont))
    
    ; Application:      
    ((app? exp)         (c-compile-app exp append-preamble cont))
    (else               (error "unknown exp in c-compile-exp: " exp))))

(define (c-compile-quote qexp)
  (let ((exp (cadr qexp)))
    (c-compile-scalars exp)))
;  // (1 . (2 . nil))
;  make_int(i2, 2);
;  make_cons(c2, &i2, nil);
;  make_int(i1, 1);
;  make_cons(c1, &i1, &c2);
;  return_check1(__lambda_1, &c1);; 
(define (c-compile-scalars args)
  (letrec (
    (num-args 0)
    (create-cons
      (lambda (cvar a b)
        (c-code/vars
          (string-append "make_cons(" cvar "," (c:body a) "," (c:body b) ");")
          (append (c:allocs a) (c:allocs b))))
    )
    (_c-compile-scalars 
     (lambda (args)
       (cond
        ((null? args)
           (c-code "nil"))
        ((not (pair? args))
         (c-compile-const args))
        (else
           (let* ((cvar-name (mangle (gensym 'c)))
                  (cell (create-cons
                          cvar-name
                          (c-compile-const (car args)) 
                          (_c-compile-scalars (cdr args)))))
             (set! num-args (+ 1 num-args))
             (c-code/vars
                (string-append "&" cvar-name)
                (append
                  (c:allocs cell)
                  (list (c:body cell))))))))))
  (c:tuple/args
    (_c-compile-scalars args) 
    num-args)))

;; c-compile-const : const-exp -> c-pair
;;
;; Typically this function is used to compile constant values such as
;; a single number, boolean, etc. However, it can be passed a quoted
;; item such as a list, to compile as a literal.
(define (c-compile-const exp)
  (cond
    ((list? exp)
     (c-compile-scalars exp))
    ((integer? exp) 
      (let ((cvar-name (mangle (gensym 'c))))
        (c-code/vars
            (string-append "&" cvar-name) ; Code is just the variable name
            (list     ; Allocate integer on the C stack
              (string-append 
                "make_int(" cvar-name ", " (number->string exp) ");")))))
    ((boolean? exp) 
      (c-code (string-append
                (if exp "quote_t" "quote_f"))))
TODO: not good enough, need to store new symbols in a table so they can
be inserted into the C program
    ((symbol? exp)
     (c-code (string-append "quote_" (symbol->string exp))))
    (else
      (error "unknown constant: " exp))))

;; c-compile-prim : prim-exp -> string
(define (c-compile-prim p)
  (let ((c-func
          (cond
            ((eq? p '+)       "__sum")
            ((eq? p '-)       "__sub")
            ((eq? p '*)       "__mul")
            ((eq? p '/)       "__div")
            ((eq? p '=)       "__num_eq")
            ((eq? p '>)       "__num_gt")
            ((eq? p '<)       "__num_lt")
            ((eq? p '>=)      "__num_gte")
            ((eq? p '<=)      "__num_lte")
            ((eq? p '%halt)     "__halt")
            ((eq? p 'display)   "prin1")
            ((eq? p 'write)     "write")
            ((eq? p 'length)    "Cyc_length")
            ((eq? p 'equal?)    "equalp")
            ((eq? p 'boolean?)  "Cyc_is_boolean")
            ((eq? p 'number?)   "Cyc_is_number")
            ((eq? p 'pair?)     "Cyc_is_cons")
            ((eq? p 'cons)      "make_cons")
            ((eq? p 'cell)      "make_cell")
            ((eq? p 'cell-get)  "cell_get")
            ((eq? p 'set-cell!) "cell_set")
            (else
              (error "unhandled primitive: " p)))))
    (cond
     ;; TODO: this is crap. if there is another function that requires a
     ;; traditional c variable assignment (IE, obj x = y) then generalize
     ;; all of this...
     ((eq? p 'length)
        (let ((cv-name (mangle (gensym 'c))))
           (c-code/vars 
            (string-append "&" cv-name)
            (list
                (string-append "integer_type " cv-name " = " c-func "(")))))
     ((prim/cvar? p)
        (let ((cv-name (mangle (gensym 'c))))
           (c-code/vars 
            (string-append "&" cv-name)
            (list
                (string-append c-func "(" cv-name)))))
     (else
        (c-code (string-append c-func "("))))))

; Does primitive create a c variable?
(define (prim/cvar? exp)
    (and (prim? exp)
         (member exp '(+ - * / cons length cell))))

; c-compile-ref : ref-exp -> string
(define (c-compile-ref exp)
  (c-code (mangle exp)))

; c-compile-args : list[exp] (string -> void) -> string
(define (c-compile-args args append-preamble prefix cont)
  (letrec ((num-args 0)
         (_c-compile-args 
          (lambda (args append-preamble prefix cont)
            (if (not (pair? args))
                (c-code "")
                (begin
                  ;(trace:debug `(c-compile-args ,(car args)))
                  (set! num-args (+ 1 num-args))
                  (c:append/prefix
                    prefix 
                    (c-compile-exp (car args) 
                      append-preamble cont)
                    (_c-compile-args (cdr args) 
                      append-preamble ", " cont)))))))
  (c:tuple/args
    (_c-compile-args args 
      append-preamble prefix cont)
    num-args)))

;; c-compile-app : app-exp (string -> void) -> string
(define (c-compile-app exp append-preamble cont)
  ;(trace:debug `(c-compile-app: ,exp))
  (let (($tmp (mangle (gensym 'tmp))))
    (let* ((args     (app->args exp))
           (fun      (app->fun exp)))
      (cond
        ((lambda? fun)
         (let* ((lid (allocate-lambda (c-compile-lambda fun))) ;; TODO: pass in free vars? may be needed to track closures
                                                               ;; properly, wait until this comes up in an example
                (cgen 
                  (c-compile-args
                     args 
                     append-preamble 
                     ""
                     cont))
                (num-cargs (c:num-args cgen)))
           (set-c-call-arity! num-cargs)
           (c-code
             (string-append
               (c:allocs->str (c:allocs cgen))
               "return_check" (number->string num-cargs) 
               "(__lambda_" (number->string lid)
               (if (> num-cargs 0) "," "") ; TODO: how to propagate continuation - cont " "
                  (c:body cgen) ");"))))

        ((prim? fun)
         (let ((c-fun 
                (c-compile-exp fun append-preamble cont))
               (c-args
                (c-compile-args args append-preamble "" cont)))
            (if (prim/cvar? fun)
              ;; Args need to go with alloc function
              (c-code/vars
                (c:body c-fun)
                (append
                  (c:allocs c-args) ;; fun alloc depends upon arg allocs
                  (list (string-append 
                    (car (c:allocs c-fun)) 
                         (if (eq? fun 'length) "" "," ) ; TODO: a special case, generalize this
                         (c:body c-args) ");"))))
              ;; Args stay with body
              (c:append
                (c:append c-fun c-args)
                (c-code ")")))))

        ((equal? '%closure-ref fun)
         (c-code (apply string-append (list
            "("
            ;; TODO: probably not the ideal solution, but works for now
            "(closure" (number->string (cadr args)) ")"
            (mangle (car args))
            ")->elt"
            (number->string (cadr args))))))

        ;; TODO: may not be good enough, closure app could be from an elt
        ((tagged-list? '%closure-ref fun)
         (let* ((comp (c-compile-args 
                         args append-preamble "  " cont)))
           (set-c-call-arity! (c:num-args comp))
           (c-code 
             (string-append
               (c:allocs->str (c:allocs comp) "\n")
               "return_funcall" (number->string (- (c:num-args comp) 1))
               "("
               (c:body comp)
               ");"))))

        ((tagged-list? '%closure fun)
         (let* ((cfun (c-compile-closure 
                        fun append-preamble cont))
                (cargs (c-compile-args
                         args append-preamble "  " cont))
                (num-cargs (c:num-args cargs)))
           (set-c-call-arity! num-cargs)
           (c-code
             (string-append
                (c:allocs->str (c:allocs cfun) "\n")
                (c:allocs->str (c:allocs cargs) "\n")
                "return_funcall" (number->string num-cargs)
                "("
                "(closure)" (c:body cfun) 
                (if (> num-cargs 0) "," "")
                (c:body cargs)
                ");"))))

        (else
         (error `(Unsupported function application ,exp)))))))

; c-compile-if : if-exp -> string
(define (c-compile-if exp append-preamble cont)
  (let* ((compile (lambda (exp)
                    (c-compile-exp exp append-preamble cont)))
         (test (compile (if->condition exp)))
         (then (compile (if->then exp)))
         (els (compile (if->else exp))))
  (c-code (string-append
   "if( !eq(quote_f, "
   (c:serialize test "  ")
   ") ){ \n"
   (c:serialize then "  ")
   "\n} else { \n"
   (c:serialize els "  ")
   "}\n"))))


;; Lambda compilation.

;; Lambdas get compiled into procedures that, 
;; once given a C name, produce a C function
;; definition with that name.

;; These procedures are stored up an eventually 
;; emitted.

; type lambda-id = natural

; num-lambdas : natural
(define num-lambdas 0)

; lambdas : alist[lambda-id,string -> string]
(define lambdas '())

; allocate-lambda : (string -> string) -> lambda-id
(define (allocate-lambda lam)
  (let ((id num-lambdas))
    (set! num-lambdas (+ 1 num-lambdas))
    (set! lambdas (cons (list id lam) lambdas))
    id))

; get-lambda : lambda-id -> (symbol -> string)
(define (get-lambda id)
  (cdr (assv id lambdas)))

(define (lambda->env exp)
    (let ((formals (lambda->formals exp)))
        (car formals)))

;; c-compile-closure : closure-exp (string -> void) -> string
;;
;; This function compiles closures generated earlier in the
;; compilation process.  Each closure is of the form:
;;
;;   (%closure lambda arg ...)
;;
;; Where:
;;  - `%closure` is the identifying tag
;;  - `lambda` is the function to execute
;;  - Each `arg` is a free variable that must be stored within
;;    the closure. The closure conversion phase tags each access
;;    to one with the corresponding index so `lambda` can use them.
;;
(define (c-compile-closure exp append-preamble cont) ; fv-lst is crap, get rid of it?
  (let* ((lam (closure->lam exp))
         (free-vars
           (map
             (lambda (free-var)
                (if (tagged-list? '%closure-ref free-var)
                    (let ((var (cadr free-var))
                          (idx (number->string (caddr free-var))))
                        (string-append 
                            "((closure" idx ")" (mangle var) ")->elt" idx))
                    (mangle free-var)))
             (closure->fv exp))) ; Note these are not necessarily symbols, but in cc form
         (cv-name (mangle (gensym 'c)))
         (lid (allocate-lambda (c-compile-lambda lam))))
  (c-code/vars
    (string-append "&" cv-name)
    (list (string-append
     "mclosure" (number->string (length free-vars)) "(" cv-name ", "
     "__lambda_" (number->string lid)
     (if (> (length free-vars) 0) "," "")
     (string-join free-vars ", ")
     ");")))))

; c-compile-formals : list[symbol] -> string
(define (c-compile-formals formals)
  (if (not (pair? formals))
      ""
      (string-append
       "object "
       (mangle (car formals))
       (if (pair? (cdr formals))
           (string-append ", " (c-compile-formals (cdr formals)))
           ""))))

; c-compile-lambda : lamda-exp (string -> void) -> (string -> string)
(define (c-compile-lambda exp)
  (let* ((preamble "")
         (append-preamble (lambda (s)
                            (set! preamble (string-append preamble "  " s "\n")))))
    (let* ((formals (c-compile-formals (lambda->formals exp)))
           (tmp-ident (mangle (car (lambda->formals exp))))
           (has-closure? 
             (and
               (> (string-length tmp-ident) 3)
               (equal? "self" (substring tmp-ident 0 4))))
           (env-closure (lambda->env exp))
           (body    (c-compile-exp     
                        (car (lambda->exp exp)) ;; car ==> assume single expr in lambda body after CPS
                        append-preamble
                        (mangle env-closure))))
      (lambda (name)
        (string-append "static void " name 
                       "(" 
                       (if has-closure? "" "closure _,") ;; TODO: seems wrong, will GC be too aggressive due to missing refs?
                        formals 
                       ") {\n"
                       preamble
                       ;"  " body "; \n"
                       (c:serialize body "  ") "; \n"
                       "}\n")))))
  
(define (mta:code-gen input-program)
  (let ((compiled-program (c-compile-program input-program)))
    (emit-c-macros)
    (emit "#include \"mta/runtime.h\"")
    
    ;; Emit lambdas:
    ; Print the prototypes:
    (for-each
     (lambda (l)
       (emit (string-append "static void __lambda_" (number->string (car l)) "() ;")))
     lambdas)
    
    (emit "")
    
    ; Print the definitions:
    (for-each
     (lambda (l)
       (emit ((cadr l) (string-append "__lambda_" (number->string (car l))))))
     lambdas)
  
    (emit "
  static void c_entry_pt(env,cont) closure env,cont; { ")
    (emit compiled-program)
    (emit "}")
    (emit *c-main-function*)))

; Unused -
;;; Echo file to stdout
;(define (emit-fp fp)
;    (let ((l (read-line fp)))
;        (if (eof-object? l)
;            (close-port fp)
;            (begin 
;                (display l) 
;                (newline)
;                (emit-fp fp)))))
;
;(define (read-runtime fp)
;  (letrec* 
;    ((break "/** SCHEME CODE ENTRY POINT **/")
;     (read-fp (lambda (header footer on-header?)
;       (let ((l (read-line fp)))
;         (cond
;           ((eof-object? l)
;             (close-port fp)
;             (cons (reverse header) (reverse footer)))
;           (else 
;             (cond
;               ((equal? l break)
;                 (read-fp header footer #f))
;               (else
;                 (if on-header?
;                   (read-fp (cons l header) footer on-header?)
;                   (read-fp header (cons l footer) on-header?))))))))))
;
;   (read-fp (list) (list) #t)))
