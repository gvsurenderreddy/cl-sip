;;;; msg.lisp -- SIP msg parsing and constructing

;; Copyright 2009 Matt Keller
;;
;; This file is part of cl-sip.
;;
;; cl-sip is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Lesser General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; cl-sip is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Lesser General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public
;; License along with cl-sip.  If not, see
;; <http://www.gnu.org/licenses/>.


; TODO
; * parsing of specific headers
; * put recommended important fields at top: via, to, from, etc
; * disallow duplicate parmaters on a single header
; * ignore disallowed headers based on msg type
; * handle stream-oriented msgs: must have content-length; must ignore leading crlfs

(in-package :cl-sip.msg)

;;; SIP Constants ------------------------------------------------------

(defparameter +crlf+ (format nil "~a~a" #\Return #\Linefeed))

(defparameter +methods+
  (symbol-name-alist '(:invite :ack :options :bye :cancel :register :options :info)))

(defun is-method (m)
  (if (assoc m +methods+) t nil))

(defun is-method-name (name)
  (aif it (member name +methods+ :key #'cdr :test #'string-equal)
       (car (car it))
       nil))

(defparameter +headers+
  (mapcar #'(lambda (s)
              (cond ((atom s) (list s (symbol-name s)))
                    ((consp s) (list (car s) (symbol-name (car s)) (symbol-name (cdr s))))))
          '(:accept
            :accept-encoding
            :accept-language
            :alert-info
            :allow
            :authentication-info
            :authorization
            :call-id
            :call-info
            (:contact . :m)
            :content-disposition
            (:content-encoding . :e)
            :content-language
            (:content-length . :l)
            (:content-type . :c)
            :cseq
            :date
            :error-info
            :expires
            :extension-header
            (:from . :f)
            :in-reply-to
            :max-forwards
            :mime-version
            :min-expires
            :organization
            :priority
            :proxy-authenticate
            :proxy-authorization
            :proxy-require
            :record-route
            :reply-to
            :require
            :retry-after
            :route
            :server
            (:subject . :s)
            (:supported . :k)
            :timestamp
            (:to . :t)
            :unsupported
            :user-agent
            (:via . :v)
            :warning
            :www-authenticate))
  "List of '(<header-symbol> <header-name>...)")

(defun is-header (sym)
  (first (find sym +headers+ :key #'first)))

(defun is-header-name (name)
  (or (first (find name +headers+
                   :key #'(lambda (h) (cdr h)) 
                   :test #'(lambda (x y) (member x y :test #'string-equal))))
      (if (scan "^x-" name) (make-keyword name) nil)))

(defparameter +non-folding-headers+
  '(:www-authenticate :authorization :proxy-authenticate :proxy-authorization)
  "Do not combine multiple headers of these sort into single headers")

(defun non-folding-header (h)
  (member h +non-folding-headers+))

(defparameter +status-codes+ '((100 . "Trying")
                               (180 . "Ringing")
                               (181 . "Call Is Being Forwarded")
                               (182 . "Queued")
                               (183 . "Session Progress")
                               (200 . "Ok")
                               (300 . "Multiple Choices")
                               (301 . "Moved Permanently")
                               (302 . "Moved Temporarily")
                               (305 . "Use Proxy")
                               (380 . "Alternative Service")
                               (400 . "Bad Request")
                               (401 . "Unauthorized")
                               (402 . "Payment Required")
                               (403 . "Forbidden")
                               (404 . "Not Found")
                               (405 . "Method Not Allowed")
                               (406 . "Not Acceptable")
                               (407 . "Proxy Authentication Required")
                               (408 . "Request Timeout")
                               (410 . "Gone")
                               (413 . "Request Entity Too Large")
                               (414 . "Request-URI Too Large")
                               (415 . "Unsupported Media Type")
                               (416 . "Unsupported URI Scheme")
                               (420 . "Bad Extension")
                               (421 . "Extension Required")
                               (423 . "Interval Too Brief")
                               (480 . "Temporarily not available")
                               (481 . "Call Leg/Transaction Does Not Exist")
                               (482 . "Loop Detected")
                               (483 . "Too Many Hops")
                               (484 . "Address Incomplete")
                               (485 . "Ambiguous")
                               (486 . "Busy Here")
                               (487 . "Request Terminated")
                               (488 . "Not Acceptable Here")
                               (491 . "Request Pending")
                               (493 . "Undecipherable")
                               (500 . "Internal Server Error")
                               (501 . "Not Implemented")
                               (502 . "Bad Gateway")
                               (503 . "Service Unavailable")
                               (504 . "Server Time-out")
                               (505 . "SIP Version not supported")
                               (513 . "Message Too Large")
                               (600 . "Busy Everywhere")
                               (603 . "Decline")
                               (604 . "Does not exist anywhere")
                               (606 . "Not Acceptable")))

(defun is-status-code (r)
  (if (assoc r +status-codes+) t nil))

(defun status-code-str (r)
  (cdr (assoc r +status-codes+)))

(defun status-code-type (code)
  (aif it (assoc (- code (mod code 100))
                 '((100 . provisional)
                   (200 . success)
                   (300 . redirection)
                   (400 . client-error)
                   (500 . server-error)
                   (600 . global-failure)))
       (cdr it)
       nil))

;;; Msg class ----------------------------------------------------

(defclass msg ()
  ((version :initarg :version
            :initform nil
            :reader version)
   (headers :initarg :headers
            :initform nil
            :accessor headers)
   (bodies  :initarg  :bodies
            :initform nil
            :reader bodies)))

(defun print-object-fields (obj stream)
  "Print all the fields of an object autoMOPically"
  (let ((class (class-of obj))
        (fmt   (if *print-pretty* "~&~S=~S" "~S=~S ")))
    (dolist (slot (sb-mop:class-slots class))
      (format stream fmt
              (sb-mop:slot-definition-name slot)
              (sb-mop:slot-value-using-class class obj slot)))))

(defmethod print-object ((m msg) stream)
  (print-unreadable-object (m stream :identity t :type t)
    (print-object-fields m stream)))

(defmethod emit ((m msg))
  (concatenate
   'string
   (format nil "~{~a~}"
           (mapcar #'(lambda (c)
                       (concatenate 'string (string (car c)) ": " (cdr c) +crlf+))
                   (headers m)))
   +crlf+))

(defmethod has-header ((m msg) header)
  (find header (headers m) :key #'name))

;; TODO: prevent multiheader addition??
(defmethod add-header ((m msg) header-symbol header-string)
  (push (make-header header-symbol header-string) (headers m))
  m)

;;; Response class ----------------------------------------------------

(defclass response (msg)
  ((status-code :initarg :status-code
                :initform (error "Need a status-code")
                :reader status-code)))

(defmethod emit ((m response))
  (with-accessors ((v version) (h headers) (s status-code) (b body)) m
    (concatenate 'string
                 (format nil "~a ~a ~a~a" v s (status-code-str s) +crlf+)
                 (call-next-method))))

;;; Request class ------------------------------------------------------

(defclass request (msg)
  ((method  :initarg :method
            :initform (error "Need a method")
            :accessor meth)
   (uri     :initarg :uri
            :accessor uri)))

(defmethod emit ((m request))
  (with-accessors ((m meth) (u uri) (v version)) m
    (concatenate 'string
                 (format nil "~a ~a ~a~a" m (emit u) v +crlf+)
                 (call-next-method))))

;;; Sip-uri class ------------------------------------------------------

(defclass sip-uri ()
  ((scheme    :initarg :scheme
              :initform 'sip
              :accessor scheme)
   (user-info :initarg :user-info
              :initform nil
              :accessor user-info)
   (host      :initarg :host
              :initform nil
              :accessor host)
   (ip        :initarg :ip
              :initform nil
              :accessor ip)
   (port      :initarg :port
              :initform nil
              :accessor port)
   (uri-parms :initarg :uri-parms
              :initform nil
              :accessor uri-parms)
   (headers   :initarg :headers
              :initform nil
              :accessor headers)))

(defmethod print-object ((obj sip-uri) stream)
  (print-unreadable-object (obj stream :identity t :type t)
    (format stream "Scheme: ~a; User-info: ~a; Host: ~a; IP: ~a; Port: ~a; Parms: ~a; Headers: ~a"
            (scheme obj) (user-info obj) (host obj) (ip obj) (port obj) (uri-parms obj) (headers obj))))

(defun alist-to-str-pairs (alist &optional (s1 "") (s2 "=")  (s3 nil))
  "Turn alist of name/value pairs into a string with various separators"
  (if alist
    (format nil (concatenate 'string "~{~a" (if s3 (concatenate 'string "~^" s3) "") "~}")
            (mapcar #'(lambda (p) (concatenate 'string s1 (car p) s2 (cdr p))) alist))
    ""))

(defmethod emit ((obj sip-uri))
  (with-accessors ((ui user-info) (h host) (p port) (ip ip) (parms uri-parms) (hdrs headers)) obj
      (format nil "sip:~a~a~a~a"
              (if ui (concatenate 'string ui "@") "")
              (concatenate 'string (if h h ip) (if p (format nil ":~a" p) ""))
              (if parms (alist-to-str-pairs parms ";" "=") "")
              (if hdrs  (concatenate 'string "?" (alist-to-str-pairs hdrs "" "=" "&")) ""))))

;;; Header -------------------------------------------------------------

(defclass header ()
  ((name      :initarg  :name
              :initform '(error "A header needs a name")
              :reader   name)
   (value     :initarg  :value
              :initform nil
              :reader   value)
   (raw-value :initform nil
              :initarg  :raw-value
              :reader   raw-value)
   (parms     :initform nil
              :initarg  :parms
              :reader   parms)))

(defmethod print-object ((obj header) stream)
  (print-unreadable-object (obj stream :identity t :type t)
    (format stream "Name: ~a; Value: ~a; Parms: ~a; Raw-value: ~a"
            (name obj) (value obj) (parms obj) (raw-value obj))))

(defun make-header (name raw-value)
  "Make a header obj given the header's name (symbol) and the
raw-value (string) of the header. The raw-value will be parsed into
`value' and `parms'"
  (destructuring-bind (value parms-alist) (header-parse-raw-value raw-value)
    (make-instance 'header :name name :value value :raw-value raw-value :parms parms-alist)))

;; TODO: msg can contain multiple :via headers, each containing parms,
;; which will get squashed into a single header with commas
;; seperators. My value/get-parm accessors don't deal with this yet.
;; See the failing TC.

;; field-name: field-value *(;parameter-name=parameter-value)
(defun header-parse-raw-value (str)
  "Return (value parms-alist)"
  (let ((parm-alist nil)
        (lst (split ";" str)))
    (if (eql 1 (length lst))
        (list str nil)
        (progn
          (dolist (phrase (cdr lst))
            (aif fvlst (split "=" phrase)
                 (setf parm-alist
                       (alist-push-uniq parm-alist (first fvlst) (second fvlst) :test #'string-equal))))
          (list (first lst) parm-alist)))))

(defmethod header-has-parm ((obj header) parm-name)
  (not (null (header-get-parm obj parm-name))))

(defmethod header-get-parm ((obj header) parm-name)
  (assoc parm-name (parms obj) :test #'string-equal))

(defmethod header-set-parm ((obj header) name value)
  (let ((parm (header-get-parm obj name)))
    (if parm
      (setf (cdr parm) value)
      (setf (slot-value obj 'parms) (acons name value (parms obj))))))

;;; Parsing ------------------------------------------------------------

(define-condition sip-parse-error (error)
  ((text :initarg :text :reader text))
  (:report (lambda (condition stream)
             (format stream "SIP Parse Error: ~a" (text condition)))))

(define-condition unknown-method-error (sip-parse-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Unknown Method Error: ~a" (text condition)))))

(defmacro sip-parse-error (fmt-str &rest args)
  `(error 'sip-parse-error :text (funcall #'format nil ,fmt-str ,@args)))

(defun can-parse-p (fn &rest args)
  "If (fn ..args..) does not throw a sip-parse-error, give (values t (fn ..args..)),
otherwise (values nil <sip-parse-error>)"
  (handler-case (apply fn args)
    (sip-parse-error (e) (values nil e))
    (:no-error (&rest args) (values t args))))

(defun parse-msg (str)
  "Parse the str into the proper msg class"
  (destructuring-bind (msg-lines body) (split-msg str)
    (unless (and msg-lines body)
      (sip-parse-error "Invalid msg -- no blank line included!"))
    (ecase (request-or-response-p (first msg-lines))
      (request  (parse-request msg-lines body))
      (response (parse-response msg-lines body)))))

(defun request-or-response-p (str)
  (let ((fields (split " " str)))
    (unless (> (length fields) 0)
      (sip-parse-error "Invalid msg!"))
    (cond ((scan "^SIP/" (trim-ws (first fields))) 'response)
          ((is-method-name (trim-ws (first fields))) 'request)
          (t (sip-parse-error "Invalid first token in msg: ~a" (trim-ws (first fields)))))))

(defun parse-request (msg-lines body)
  (let ((uri-vals (parse-uri-line (first msg-lines)))
        (headers (mapcar #'(lambda (h) (make-header (car h) (cdr h)))
                         (parse-headers (cdr msg-lines)))))
    (make-instance 'request
                   :method  (first uri-vals)
                   :uri     (second uri-vals)
                   :version (third uri-vals)
                   :headers headers
                   :bodies  (parse-bodies body))))

(defun parse-response (msg-lines body)
  (let ((status-vals (parse-status-line (first msg-lines)))
        (headers (mapcar #'(lambda (h) (make-header (car h) (cdr h)))
                         (parse-headers (cdr msg-lines)))))
    (make-instance 'response
                   :status-code (second status-vals)
                   :version (first status-vals)
                   :headers headers
                   :bodies  (parse-bodies body))))

(defun split-msg (str)
  "Return list: (all msg data above the bodies split by CRLF, body section"
  (aif it (cl-ppcre:split (format nil "~a~a" +crlf+ +crlf+) str)
       (list (cl-ppcre:split +crlf+ (first it)) (second it))
       nil))

(defun parse-uri-line (line)
  "Parse the uri line from string; return (method uri version)"
  (let ((fields (cl-ppcre:split " +" line)))
    (if (= (length fields) 3)
      (list (parse-method (first fields))
            (parse-uri (second fields))
            (parse-version (third fields)))
      (sip-parse-error "Invalid SIP-URI line: ~a " line))))

(defun parse-status-line (line)
  "Parse first line of response msg: return '(version code reason-phrase)"
  (scan-to-stringz (version status-code reason) "([^ ]+)? (\\d{3})? (.+)" line
    (if (and version status-code reason)
        (list (parse-version version)
              (parse-response-code status-code)
              reason)
        (sip-parse-error "Invalid Status-Line: ~a" line))))

(defun parse-response-code (str)
  (let ((int (parse-integer str :junk-allowed t)))
    (cond ((null int)
           (sip-parse-error "Invalid Status-Code: ~a" str))
          ((is-status-code int)
           int)
          ((is-status-code (- int (mod int 100))) ;; consider x00
           (let ((new-int (- int (mod int 100))))
             (if (eq (status-code-type new-int) 'provisional)
                 183 ;; all unknown prov response become 183
                 new-int)))
          (t (sip-parse-error "Invalid Status-Code: ~a" str)))))

(defun parse-method (m)
  (aif msym (is-method-name m)
       msym
       (restart-case (error 'unknown-method-error :text m)
         (allow-method () (make-keyword m))
         (use-new-value (value) :interactive read-new-value value))))

(defun parse-uri-scheme (str)
  (cond ((string-equal str "sip") 'sip)
        ((string-equal str "sips") 'sips)
        (t (sip-parse-error "Invalid uri scheme: ~a" str))))

(defun parse-hostport (str)
  "Give (<hostname> <ip> <port>) from str"
  (let ((fields (split ":" str))
        (port nil)
        (hostname nil)
        (ip nil))
    (when (= (length fields) 2)
      (setf port (parse-integer (second fields) :junk-allowed t)))
    ;; host must be valid domain name or ipv4 -- skip ipv6 for now
    (cond ((scan "(\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3})" (first fields))
           (setf ip (first fields)))
          ((scan "([\\w-]+\\.)*([a-zA-Z]+)" (first fields)) ;; TODO: close, but not quite
           (setf hostname (first fields)))
          (t (sip-parse-error "Invalid hostport: ~a" str)))
    (list hostname ip port)))

(defun parse-uri (str)
  "Parse the SIP-URI line into a sip-uri object"
  (scan-to-stringz (scheme user-info hostport uri-parms hdr-clause headers) "(sips?):(.*@)?([^;]+)(;[^\\?]*)?(\\?(.*))?" str
    (declare (ignore hdr-clause))
    (when (not scheme) (sip-parse-error "Invalid SIP-URI: ~a" str))
    (let ((uri (make-instance 'sip-uri)))
      (setf (scheme uri) (parse-uri-scheme scheme))
      (when user-info (setf (user-info uri) (string-right-trim '(#\@) user-info)))
      (when hostport
        (let ((hp (parse-hostport hostport)))
          (when hp
            (setf (host uri) (first hp))
            (setf (ip uri)   (second hp))
            (setf (port uri) (third hp)))))
      (when uri-parms (parse-uri-parms uri (string-left-trim '(#\;) uri-parms)))
      (when headers (parse-uri-headers uri headers))
      uri)))

(defun parse-extended-uri (sip-uri str)
  (let ((fields (split "\\?" str)))
    (when fields
      (parse-uri-parms sip-uri (first fields))
      (when (= (length fields) 2)
        (parse-uri-headers sip-uri (second fields))))
    sip-uri))

(defun parse-uri-parms (sip-uri str)
  "Add any uri-parms in str to sip-uri"
  (let ((fields (split "\;" str))
        (parms nil))
    (when fields
      (dolist (f fields)
        (scan-to-stringz (name value) "(.*)=(.*)" f
          (when (and name value)
            (setf parms (acons name value parms))))))
    (setf (uri-parms sip-uri) parms)))

(defun parse-uri-headers (sip-uri str)
  "Add any uri headers in str to sip-uri"
  (let ((fields (split "\&" str))
        (parms nil))
    (when fields
      (dolist (f fields)
        (scan-to-stringz (name value) "(.*)=(.*)" f
          (when (and name value)
            (setf parms (acons name value parms))))))
    (setf (headers sip-uri) parms)))

(defun parse-version (v)
  (if (scan "SIP/\\d\\.\\d" v)
      v
      (sip-parse-error "Invalid SIP-Version: ~a" v)))

(defun parse-bodies (str) str)

(defun parse-header-line (str)
  "Give '(hdr-symbol . hdr-value-string) if given a legal header line, otherwise nil"
  (scan-to-stringz (name value) "([^:]*)\\s*:(.*)" str
    (cond
      ((and name value)
       (aif hdr (is-header-name (trim-ws name))
            (cons hdr (trim-ws value))
            (warn "Ignoring unknown header: ~a" name)))
      (t nil))))

(defun parse-headers (lines)
  "Return alist of header/header-value pairs.

This function works by successive filterings of lists. In the parse-line
pass, the raw header lines are transformed into an alist of hdr/value
pairs. If the header line is a continuation (starts with whitespace),
its hdr symbol becomes 'continuation. In the hdr-continuation-reduction
pass, the continutations are squashed into their preceeding alist
pairs. In the multi-hdr-combination pass, pairs with the same car (same
header) are combined with a comma separating their values."
  (labels ((parse-line (line)
             "Parse line to either nil or '(hdr-symbol . hdr-value) cons"
             (cond
               ((string= line "") nil)
               ((scan "^[\\s+]" line) (cons 'continuation (trim-ws line)))
               (t (parse-header-line line))))
           (hdr-continuation-reduction (alist c)
             "Squash together cdrs when 2nd cons has car of 'continuation"
             (cond ((eq (car c) 'continuation)
                    (aif prev-pair (first (last alist))
                         (rplacd prev-pair (concatenate 'string (cdr prev-pair) " " (cdr c)))
                         (sip-parse-error "Invalid header: ~a" (car c)))
                      alist)
                   (t (append alist (list c)))))
           (multi-hdr-combination (lst &optional (acc nil))
             "Combine alist entries with eq cars to have cdrs separated by commas"
             (cond ((null lst) acc)
                   ((and (assoc (caar lst) acc)
                         (not (non-folding-header (caar lst))))
                    (let ((hdr (assoc (caar lst) acc))
                          (newvalue (cdr (car lst))))
                      (rplacd hdr (join-str "," (cdr hdr) newvalue))
                      (multi-hdr-combination (cdr lst) acc)))
                   (t (multi-hdr-combination(cdr lst) (cons (car lst) acc))))))
    (multi-hdr-combination
     (reduce #'hdr-continuation-reduction
             (remove-if #'null (mapcar #'parse-line lines))
             :initial-value nil))))

;;; Testing utils ------------------------------------------------------

(defun build-msg-str (hdr-lst &optional (body-lst nil))
  (declare (ignore body-lst))
  (concatenate 'string
               (reduce #'(lambda (x y) (concatenate 'string x +crlf+ y)) hdr-lst)
               +crlf+
               +crlf+
               "...fake-body..."))

(defsuite msg-suite)

(in-suite msg-suite)

(deftest test-is-header ()
  (is (is-header :to))
  (is (is-header :from))
  (is (not (is-header nil)))
  (is (not (is-header :foobar)))
  (is (eq (is-header-name "to") :to))
  (is (eq (is-header-name "TO") :to))
  (is (null (eq (is-header-name "") :to)))
  (is (null (eq (is-header-name nil) :to)))
  (is (null (eq (is-header-name "x-foo") :to))))

(deftest test-parse-headers ()
  (flet ((header-is (h val alist)
           (let ((real-val (cdr (assoc h alist))))
             (is (string-equal real-val val) "Value of header ~a should be ~a, was ~a" h val real-val))))
    (header-is :to "matt" (parse-headers '("to: matt" "from: bob")))
    (header-is :from "bob" (parse-headers '("t: matt" "f: bob  ")))
    (header-is :to "matt keller" (parse-headers '("to: matt" " keller" "from: bob")))
    (header-is :from "bob,foop" (parse-headers '("to: matt" "from: bob" "from: foop ")))
    (is (can-parse-p #'parse-headers '("tooo: matt"))) ; ignore unknown header
    (header-is :x-header "foop" (parse-headers '("to: matt" "x-header: foop")))))

(deftest test-req-parse ()
  (let ((req (parse-msg (build-msg-str '("INVITE sip:matthewk@nortel.com:5060 SIP/2.0"
                                         "t: matthewk"
                                         "f: bob")))))
    (is (string= (meth req) "INVITE"))
    (is (string= (version req) "SIP/2.0"))
    (is (string= (host (uri req)) "nortel.com"))
    (is (string= (ip (uri req)) nil))
    (is (string= (user-info (uri req)) "matthewk"))
    (is (= (port (uri req)) 5060))
    (is (string= (value (has-header req :to)) "matthewk"))
    (is (string= (value (has-header req :from)) "bob"))))

(deftest test-resp-parse ()
  (let ((resp (parse-msg (build-msg-str '("SIP/2.0 200 Ok" "t: bob" "f: matt")))))
    (is (string= (version resp) "SIP/2.0"))
    (is (= (status-code resp) 200))
    (is (string= (status-code-str (status-code resp)) "Ok"))
    (is (string= (value (has-header resp :to)) "bob"))
    (is (string= (value (has-header resp :from)) "matt"))))

(deftest test-request-or-response-p ()
  (is (not (can-parse-p #'request-or-response-p "")))
  (is (not (can-parse-p #'request-or-response-p " ")))
  (is (eq 'response (request-or-response-p "SIP/2.0 200 Ok")))
  (is (not (can-parse-p #'request-or-response-p "sip/2.0 ")))
  (is (not (can-parse-p #'request-or-response-p " SIP")))
  (is (eq 'request (request-or-response-p "INVITE sips:")))
  (is (eq 'request (request-or-response-p "ACK")))
  (is (eq 'request (request-or-response-p "cancel "))))

(defun crlfify (str)
  (concatenate 'string
               (reduce #'(lambda (acc str) (concatenate 'string acc str))
                       (mapcar #'(lambda (l) (concatenate 'string l +crlf+)) (split "\\n" str))
                       :initial-value "")
               +crlf+ +crlf+))

(deftest test-example-msgs ()
  (is (can-parse-p #'parse-msg (crlfify
"REGISTER sip:registrar.biloxi.com SIP/2.0
Via: SIP/2.0/UDP bobspc.biloxi.com:5060;branch=z9hG4bKnashds7
Max-Forwards: 70
To: Bob <sip:bob@biloxi.com>
From: Bob <sip:bob@biloxi.com>;tag=456248
Call-ID: 843817637684230@998sdasdh09
CSeq: 1826 REGISTER
Contact: <sip:bob@192.0.2.4>
Expires: 7200
Content-Length: 0")))
  (let ((msg (parse-msg (crlfify
"SIP/2.0 200 OK
Via: SIP/2.0/UDP bobspc.biloxi.com:5060;branch=z9hG4bKnashds7
 ;received=192.0.2.4
To: Bob <sip:bob@biloxi.com>;tag=2493k59kd
From: Bob <sip:bob@biloxi.com>;tag=456248
Call-ID: 843817637684230@998sdasdh09
CSeq: 1826 REGISTER
Contact: <sip:bob@192.0.2.4>
Expires: 7200
Content-Length: 0"))))
    (is (string= (value (has-header msg :via)) "SIP/2.0/UDP bobspc.biloxi.com:5060"))
    (is (string= (cdr (header-get-parm (has-header msg :via) "branch")) "z9hG4bKnashds7 "))
    (is (string= (cdr (header-get-parm (has-header msg :via) "received")) "192.0.2.4")))
  (is (can-parse-p #'parse-msg (crlfify
"INVITE sip:bob@biloxi.com SIP/2.0
Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKnashds8
Max-Forwards: 70
To: Bob <sip:bob@biloxi.com>
From: Alice <sip:alice@atlanta.com>;tag=1928301774
Call-ID: a84b4c76e66710
CSeq: 314159 INVITE
Contact: <sip:alice@pc33.atlanta.com>
Content-Type: application/sdp
Content-Length: 142")))
    (is (can-parse-p #'parse-msg (crlfify
"INVITE sip:bob@biloxi.com SIP/2.0
Via: SIP/2.0/UDP bigbox3.site3.atlanta.com;branch=z9hG4bK77ef4c2312983.1
Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKnashds8
 ;received=192.0.2.1
Max-Forwards: 69
To: Bob <sip:bob@biloxi.com>
From: Alice <sip:alice@atlanta.com>;tag=1928301774
Call-ID: a84b4c76e66710
CSeq: 314159 INVITE
Contact: <sip:alice@pc33.atlanta.com>
Content-Type: application/sdp
Content-Length: 142")))
    (let ((msg (parse-msg (crlfify
"SIP/2.0 180 Ringing
Via: SIP/2.0/UDP server10.biloxi.com;branch=z9hG4bK4b43c2ff8.1
 ;received=192.0.2.3
Via: SIP/2.0/UDP bigbox3.site3.atlanta.com;branch=z9hG4bK77ef4c2312983.1
 ;received=192.0.2.2
Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKnashds8
 ;received=192.0.2.1
To: Bob <sip:bob@biloxi.com>;tag=a6c85cf
From: Alice <sip:alice@atlanta.com>;tag=1928301774
Call-ID: a84b4c76e66710
Contact: <sip:bob@192.0.2.4>
CSeq: 314159 INVITE
Content-Length: 0"))))
      (is (string= (value (has-header msg :via))
                   (concatenate 'string
                                "SIP/2.0/UDP server10.biloxi.com;branch=z9hG4bK4b43c2ff8.1 ;received=192.0.2.3,"
                                "SIP/2.0/UDP bigbox3.site3.atlanta.com;branch=z9hG4bK77ef4c2312983.1 ;received=192.0.2.2,"
                                "SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKnashds8 ;received=192.0.2.1")))))
