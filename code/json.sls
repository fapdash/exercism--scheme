;; JSON implementation for Scheme
;; See http://www.json.org/ or http://www.crockford.com/JSON/index.html
;;
;; Copyright (c) 2005 Tony Garnock-Jones <tonyg@kcbbs.gen.nz>
;; Copyright (c) 2005 LShift Ltd. <query@lshift.net>
;;
;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;; SPDX-License-Identifier: MIT

#!r6rs

(library (json)
  (export json-write
          json-read)

  (import
   (except (rnrs) define-record-type error)
   (rnrs r5rs)
   (rnrs mutable-pairs)
   (only (srfi :1 lists) lset-union append-map fold)
   (srfi :6 basic-string-ports)
   (srfi :9 records)
   (srfi :23 error)
   (only (chezscheme) include)
   (packrat))

  ;; write-json :: sexp -> json
  ;; The interface is three-fold and implemented as a case-lambda
  ;; 1 argument  = simple unformatted json
  ;; 2 arguments = first must be the symbolic representation of a scheme object
  ;;               second must be 'pretty
  ;;                 any other symbol will throw an error
  ;; 3 arguments = first must be the symbolic representation of a scheme object
  ;;               second must be 'pretty
  ;;                 any other symbol will throw an error
  ;;               third must be the tabpstop size defined in spaces
  (define json-write
    (let (;; toggle pretty printing
          (pretty? #f)
          ;; internal control var for pretty indentation
          (indent-level 0)
          ;; default tabstop size can be changed
          (tabstop-size 2))

      ;; Print the indentation level
      (define (display-level p)
        (display (make-string (* indent-level tabstop-size) #\space) p))

      (define (write-ht vec p)
        (display "{" p)
        (when pretty?
          (display "\n" p)
          (set! indent-level (+ indent-level 1)))
        (do ((need-comma #f #t)
             (vec vec (cdr vec)))
            ((null? vec))
          (if need-comma
              (begin (display "," p)
                     (if pretty?
                         (display "\n" p)
                         (display " " p)))
              (set! need-comma #t))
          (let* ((entry (car vec))
                 (k (car entry))
                 (v (cdr entry)))
            (when pretty? (display-level p))
            (display "\"" p)
            (cond
             ((symbol? k) (display (symbol->string k) p))
             ((string? k) (display k p))
             (else (error "Invalid JSON table key in json-write" k)))
            (display "\": " p)
            (write-any v p)))
        (when pretty?
          (set! indent-level (- indent-level 1))
          (display "\n" p)
          (display-level p))
        (display "}" p))

      (define (write-array a p)
        (display "[" p)
        (when pretty?
          (display "\n" p)
          (set! indent-level (+ indent-level 1)))
        (let ((need-comma #f))
          (for-each (lambda (v)
                      (if need-comma
                          (if pretty?
                              (display ",\n" p)
                              (display "," p))
                          (set! need-comma #t))
                      (when pretty? (display-level p))
                      (write-any v p))
                    a))
        (when pretty?
          (set! indent-level (- indent-level 1))
          (display "\n" p)
          (display-level p))
        (display "]" p))

      (define (write-any x p)
        (cond
         ((or (string? x)
              (number? x)) (write x p))
         ((boolean? x) (display (if x "true" "false") p))
         ((symbol? x)
          (write (if (eq? x 'null) 'null (symbol->string x)) p))
         ((null? x) (display "null" p))
         ((and (list? x)
               (pair? (car x))
               (not (pair? (caar x))))
          (write-ht x p))
         ((list? x) (write-array x p))
         (else (error "Invalid JSON object in json-write" x))))

      (case-lambda
        ;; For default unformatted json rendering
        ((obj)
         (set! pretty? #f)
         (write-any obj (current-output-port)))
        ;; For default Pretty Printing with a tabstop of 2 spaces
        ((obj msg)
         (case msg
           ((pretty)
            (set! pretty? #t)
            (set! tabstop-size 2)
            (write-any obj (current-output-port)))
           (else (error 'json-write "Invalid message" msg))))
        ;; Pretty Print with custom tabsize defined in spaces
        ((obj msg tabsize)
         (case msg
           ((pretty)
            (set! pretty? #t)
            (set! tabstop-size tabsize)
            (write-any obj (current-output-port)))
           (else (error 'json-write "invalid message" msg)))))))

  (define json-read
    (let ()
      (define (generator p)
        (let ((ateof #f)
              (pos (top-parse-position "<?>")))
          (lambda ()
            (if ateof
                (values pos #f)
                (let ((x (read-char p)))
                  (if (eof-object? x)
                      (begin
                        (set! ateof #t)
                        (values pos #f))
                      (let ((old-pos pos))
                        (set! pos (update-parse-position pos x))
                        (values old-pos (cons x x)))))))))

      (define parser
        (packrat-parser (begin
                          (define (white results)
                            (if (char-whitespace? (parse-results-token-value results))
                                (white (parse-results-next results))
                                (comment results)))
                          (define (skip-comment-char results)
                            (comment-body (parse-results-next results)))
                          (define (skip-to-newline results)
                            (if (memv (parse-results-token-value results) '(#\newline #\return))
                                (white results)
                                (skip-to-newline (parse-results-next results))))
                          (define (token str)
                            (lambda (starting-results)
                              (let loop ((pos 0) (results starting-results))
                                (if (= pos (string-length str))
                                    (make-result str results)
                                    (if (char=? (parse-results-token-value results) (string-ref str pos))
                                        (loop (+ pos 1) (parse-results-next results))
                                        (make-expected-result (parse-results-position starting-results) str))))))
                          (define (interpret-string-escape results k)
                            (let ((ch (parse-results-token-value results)))
                              (k (cond
                                  ((assv ch '((#\b . #\backspace)
                                              (#\n . #\newline)
                                              (#\f . #\page)
                                              (#\r . #\return)
                                              (#\t . #\tab))) => cdr) ;; we don't support the "u" escape for unicode
                                  (else ch))
                                 (parse-results-next results))))
                          (define (jstring-body results)
                            (let loop ((acc '()) (results results))
                              (let ((ch (parse-results-token-value results)))
                                (case ch
                                  ((#\\) (interpret-string-escape (parse-results-next results)
                                                                  (lambda (val results)
                                                                    (loop (cons val acc) results))))
                                  ((#\") (make-result (list->string (reverse acc)) results))
                                  (else (loop (cons ch acc) (parse-results-next results)))))))
                          (define (jnumber-body starting-results)
                            (let loop ((acc '()) (results starting-results))
                              (let ((ch (parse-results-token-value results)))
                                (if (memv ch '(#\- #\+ #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9 #\. #\e #\E))
                                    (loop (cons ch acc) (parse-results-next results))
                                    (let ((n (string->number (list->string (reverse acc)))))
                                      (if n
                                          (make-result n results)
                                          (make-expected-result (parse-results-position starting-results) 'number)))))))
                          any)
                        (any ((white '#\{ entries <- table-entries white '#\}) entries)
                             ((white '#\[ entries <- array-entries white '#\]) entries)
                             ((s <- jstring) s)
                             ((n <- jnumber) n)
                             ((white (token "true")) #t)
                             ((white (token "false")) #f)
                             ((white (token "null")) '()))
                        (comment (((token "/*") b <- comment-body) b)
                                 (((token "//") b <- skip-to-newline) b)
                                 (() 'whitespace))
                        (comment-body (((token "*/") w <- white) w)
                                      ((skip-comment-char) 'skipped-comment-char))
                        (table-entries ((a <- table-entries-nonempty) a)
                                       (() '()))
                        (table-entries-nonempty ((entry <- table-entry white '#\, entries <- table-entries-nonempty) (cons entry entries))
                                                ((entry <- table-entry) (list entry)))
                        (table-entry ((key <- jstring white '#\: val <- any) (cons (string->symbol key) val)))
                        (array-entries ((a <- array-entries-nonempty) a)
                                       (() '()))
                        (array-entries-nonempty ((entry <- any white '#\, entries <- array-entries-nonempty) (cons entry entries))
                                                ((entry <- any) (list entry)))
                        (jstring ((white '#\" body <- jstring-body '#\") body))
                        (jnumber ((white body <- jnumber-body) body))
                        ))

      (define (read-any p)
        (let ((result (parser (base-generator->results (generator p)))))
          (if (parse-result-successful? result)
              (parse-result-semantic-value result)
              (error "JSON Parse Error"
                     (let ((e (parse-result-error result)))
                       (list 'json-parse-error
                             (parse-position->string (parse-error-position e))
                             (parse-error-expected e)
                             (parse-error-messages e)))))))

      (lambda maybe-port
        (read-any (if (pair? maybe-port) (car maybe-port) (current-input-port))))))

  )
