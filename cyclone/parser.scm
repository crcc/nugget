;; Helper functions
(define (add-tok tok toks quoted?)
  (if quoted?
     (cons (cons 'quote (cons tok '())) toks)
     (cons tok toks)))

;; Add a token to the list, quoting it if necessary
(define (->tok lst)
  (parse-atom (reverse lst)))

;; Get completed list of tokens
;; TODO: better name for this function?
(define (with-tok tok toks quoted?)
  (if (null? tok)
    toks
    (add-tok (->tok tok) toks quoted?)))

;; Did we read a dotted list
(define (dotted? lst) 
  (and (> (length lst) 2)
       (equal? (cadr (reverse lst)) (string->symbol "."))))

;; Convert a list read by the reader into an improper list
(define (->dotted-list lst)
  (cond
    ((null? lst) '())
    ((equal? (car lst) (string->symbol "."))
     (cadr lst))
    (else
      (cons (car lst) (->dotted-list (cdr lst))))))

(define (parse-error msg lnum cnum)
  (error
    (string-append
      "Error (line "
      (number->string lnum)
      ", char "
      (number->string cnum)
      "): "
      msg)))

;; TODO: would be best if these did not have to be global
(define *line-num* #f)
(define *char-num* #f)

;; Main lexer/parser
(define (cyc-read-all fp)
  (set! *line-num* 1)
  (set! *char-num* 0)
  (_cyc-read-all fp 0))

(define (_cyc-read-all fp parens)
  (letrec (
   ;; Keep looping, adding finished token if there is one
   (loop/tok (lambda (tok toks comment? quoted? parens)
                (if (null? tok)
                    (loop '() toks comment? quoted? parens)
                    (loop '() (add-tok (->tok tok) toks quoted?) comment? #f parens)))) ; read tok, no more '
   ;; Loop over input
   (loop (lambda (tok toks comment? quoted? parens)
    (set! *char-num* (+ 1 *char-num*))
    (let ((c (read-char fp)))
      (cond
        ((eof-object? c) 
         (if (> parens 0)
             (parse-error "missing closing parenthesis" *line-num* *char-num*))
         (reverse (with-tok tok toks quoted?)))
        (comment?
         (if (eq? c #\newline)
             (begin
                (set! *line-num* (+ 1 *line-num*))
                (set! *char-num* 0)
                (loop '() toks #f quoted? parens))
             (loop '() toks #t quoted? parens)))
        ((char-whitespace? c)
         (if (equal? c #\newline) (set! *line-num* (+ 1 *line-num*)))
         (if (equal? c #\newline) (set! *char-num* 0))
         (loop/tok tok toks #f quoted? parens))
        ((eq? c #\;)
         (loop/tok tok toks #t quoted? parens))
        ((eq? c #\')
         (if (null? tok)
             (loop '() toks comment? #t parens)
             (loop '() (add-tok (->tok tok) toks quoted?) comment? #t parens)))
        ((eq? c #\()
         (let ((sub (_cyc-read-all fp (+ parens 1)))
               (toks* (with-tok tok toks quoted?)))
            (loop 
              '() 
              (add-tok 
                (if (dotted? sub)
                    (->dotted-list sub)
                    sub)
                toks* 
                quoted?) 
              #f #f parens)))
        ((eq? c #\))
         (if (= parens 0)
             (parse-error "unexpected closing parenthesis" *line-num* *char-num*))
         (reverse (with-tok tok toks quoted?)))
        ((eq? c #\")
         (parse-error "Unable to parse strings at this time" *line-num* *char-num*))
        ((eq? c #\#)
         (if (null? tok)
           ;; # reader
           (let ((next-c (read-char fp)))
              (set! *char-num* (+ 1 *char-num*))
              (cond
                ;; Do not use add-tok below, no need to quote a bool
                ((eq? #\t next-c) (loop '() (cons #t toks) #f #f parens))
                ((eq? #\f next-c) (loop '() (cons #f toks) #f #f parens))
                (else
                  (parse-error "Unhandled input sequence" *line-num* *char-num*))))
           ;; just another char...
           (loop (cons c tok) toks #f quoted? parens)))
        (else
          (loop (cons c tok) toks #f quoted? parens)))))))
   (loop '() '() #f #f parens)))

;; parse-atom -> [chars] -> literal
(define (parse-atom a)
  (cond 
    ((char-numeric? (car a))
     (string->number  ;; TODO: this is cheating! need to do this, too.
                      ;; but, it could be done by a library function
                      ;; exposed as string->number... so, ok here
       (list->string a)))
    (else
     (string->symbol
       (list->string a)))))

;(let ((fp (open-input-file "tests/begin.scm")))
;(let ((fp (open-input-file "tests/quote.scm")))
;  (write (cyc-read-all fp)))

;(define (display-file filename)
;  (call-with-input-file filename
;    (lambda (port)
;      (let loop ()
;    (let ((thing (read-char port)))
;      (if (not (eof-object? thing))
;          (begin
;        (write-char thing)
;        (loop))))))))
;