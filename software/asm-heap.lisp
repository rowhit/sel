;;; asm-heap.lisp --- parse assembly code into asm-line-info structs
(defpackage :software-evolution-library/software/asm-heap
  (:nicknames :sel/software/asm-heap :sel/sw/asm-heap)
  (:use :common-lisp
        :alexandria
        :arrow-macros
        :named-readtables
        :curry-compose-reader-macros
        :iterate
        :split-sequence
        :cl-ppcre
        :software-evolution-library
        :software-evolution-library/utility
        :software-evolution-library/software/simple
        :software-evolution-library/software/asm
        :software-evolution-library/software/super-mutant)
  (:export :asm-heap
           :line-heap
           :function-index
           :function-bounds-file
           :super-owner
           :asm-line-info
           :asm-line-info-text
           :asm-line-info-tokens
           :asm-line-info-type
           :asm-line-info-label
           :asm-line-info-opcode
           :asm-line-info-operands
           :asm-line-info-id
           :asm-line-info-orig-file
           :asm-line-info-orig-line
           :asm-line-info-address
           :function-index-entry
           :function-index-entry-name
           :function-index-entry-start-line
           :function-index-entry-start-address
           :function-index-entry-end-line
           :function-index-entry-end-address
           :function-index-entry-is-leaf
           :function-index-entry-declarations
           :insert-new-line
           :insert-new-lines
           :parse-asm-line))
(in-package :software-evolution-library/software/asm-heap)
(in-readtable :curry-compose-reader-macros)

(defstruct (asm-line-info (:copier copy-asm-line-info))
  text     ; original text
  tokens   ; list of tokens after parsing
  type     ; empty (white space/comments), decl, data, label-decl, op)
  label    ; for operations which refer to labels
  opcode   ; for operations
  operands ; the operands that are associated with the opcode
  id       ; unique index in heap, sequential starting at 0
  orig-file   ; path of the orignal .asm file that was loaded (if any)
  orig-line ; line number (0-based) of line in original .asm file (if any)
  address)  ; original address of code or data

(defstruct function-index-entry
  "Entry into the index, which is a vector of all the functions in the file."
  name              ; function name
  start-line        ; first line index, zero-based, of genome
  start-address     ; address of first line
  end-line          ; last line index, zero-based, of genome
  end-address       ; address of last line
  is-leaf           ; true, if function does not make any calls
  declarations)     ; list of declaration lines found for the function

;;; This read-table and package are used for parsing ASM instructions.
(defvar *assembler-x86-readtable* (copy-readtable))
(defpackage :software-evolution-library/asm (:nicknames :sel/asm))

;;
;; treat some characters such as : and , as special tokens
;;
(set-macro-character #\: (lambda (stream ch)(declare (ignore stream ch)) :colon)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\, (lambda (stream ch)(declare (ignore stream ch)) :comma)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\[ (lambda (stream ch)
			   (declare (ignore stream ch))
			   :\[)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\] (lambda (stream ch)
			   (declare (ignore stream ch))
			   :\])
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\+ (lambda (stream ch)
			   (declare (ignore stream ch))
			   :+)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\* (lambda (stream ch)
			   (declare (ignore stream ch))
			   :*)
		     nil
		     *assembler-x86-readtable*)

;; If we encounter a single quote, look for the terminating quote.
(set-macro-character
 #\'
 (lambda (stream ch)
   (declare (ignore ch))
   (let ((chars nil)(eof (cons nil nil)))
     (flet ((get-char ()
              (let ((ch (read-char stream nil eof t)))
                (when (eq ch eof)
                  (error "Unterminated single-quoted string found"))
                ch)))
       (do ((ch (get-char) (get-char))
            (count 0 (1+ count)))
           ((char= ch #\')
            (make-array count
                        :element-type 'character
                        :initial-contents (nreverse chars)))
         ;; handle '\' as an escape character
         (push (if (char= ch #\\)(get-char) ch) chars)))))

 nil
 *assembler-x86-readtable*)

(defun tokenize-asm-line (line)
  "Take a line of text from a .asm file, and, and converts it to tokens."
  (with-input-from-string (s line)
    (do* ((*readtable* *assembler-x86-readtable*)
	  (*package* (find-package :sel/asm))
	  (result '())
	  (eof (cons 0 0))
	  (token (read s nil eof)(read s nil eof)))
	 ((eq token eof)(nreverse result))
	(push token result))))

(defun token-label-p (token)
  (and (symbolp token)
       (char= (char (symbol-name token) 0) #\$)))

(defun branch-op-p (token)
  "Returns true iff the token represents a jump operation. We assume it
is a jump operator if the first letter is #\j or #\J. For our purposes
we are excluding CALL instructions."
  (and (symbolp token)
       (or
	(char= (char (symbol-name token) 0) #\j)
	(char= (char (symbol-name token) 0) #\J))))

;;; Given a list of tokens representing the line, returns either of:
;;;     :nothing
;;;     :declaration
;;;     :data
;;;     :label
;;;     :operation
(defun parse-line-type (tokens)
  (cond ((null tokens) ':empty)
	((and (token-label-p (first tokens)) ; first token symbol beg. with '$'?
	      (eq (second tokens) :colon))  ; followed by a ':'?
	 ':label-decl)
	((or (member 'sel/asm::db tokens)
	     (member 'sel/asm::dq tokens)
	     (member 'sel/asm::dd tokens)
	     (member 'sel/asm::dw tokens))
	 ':data)
	((member (first tokens)
                 '(sel/asm::align
                   sel/asm::section
                   sel/asm::extern
                   sel/asm::%define
                   sel/asm::global))
	 ':decl)
	((and (token-label-p (first tokens))
	      (eq (second tokens) 'sel/asm::equ))
	 ':decl)
	(t ':op)))     ;; use this as catch-all for anything else

;;;
;;; takes a line of text from a .asm file, and, and returns 1 or 2
;;; asm-line-info structs.  If the line begins with a label, the line
;;; is split into two lines: the label, and the remaining
;;; text/tokens. In this case 2 asm-line-info structs are returned.
;;; Otherwise, as single asm-line-info is returned.
;;;
(defun parse-asm-line (line)
  (let* ((tokens (tokenize-asm-line line))
	 (info (make-asm-line-info :text line :tokens tokens)))

    ;; see if there is a comment: "orig ea=0xnnnnnnnn" which specifies
    ;; the original address of code or data
    (let* ((addr-comment "orig ea=0x")
	   (addr-pos (search addr-comment line :from-end t :test 'equal)))
      (if addr-pos
	  (setf (asm-line-info-address info)
		(parse-integer line
			       :radix 16
			       :start (+ (length addr-comment) addr-pos)
			       :junk-allowed t))))

    ;; Determine type of line
    (let ((line-type (parse-line-type tokens)))
      (setf (asm-line-info-type info) line-type)

      (case line-type
	(:label-decl (let* ((label (first tokens))
                            (label-end (position #\: line))
                            (line1 (subseq line 0 (+ label-end 1)))
                            (line2 (concatenate 'string
				    "       "
				    (subseq line (+ label-end 1))))
                            (next-info (parse-asm-line line2))) ;; recurse!
                       (setf (asm-line-info-text info) line1)
                       (setf (asm-line-info-tokens info) (list label ':colon))
                       (setf (asm-line-info-label info) label)
                       (if (and next-info (not (eq (asm-line-info-type
                                                    (car next-info))
                                                   ':empty)))
                           ;; If an empty line follows the label, discard it.
                           (cons info next-info)
                           (progn
                             ; Restore full text line.
                             (setf (asm-line-info-text info) line)
                             (list info)))))
	(:empty (list info))
	(:op (setf (asm-line-info-opcode info) (first tokens))
	     (let ((comma-pos (position ':comma (rest tokens))))
	       (setf (asm-line-info-operands info)
		     (if comma-pos
			 (list
			  (subseq (rest tokens) 0 comma-pos)
			  (subseq (rest tokens) (+ comma-pos 1)))
			 (list (rest tokens)))))
	     (list info))
	(:data (list info))
	(:decl (list info))))))

;;;
;;; Convert an operand (from ASM-LINE-INFO-OPERANDS list) to text string.
;;;
(defun format-asm-operand (op) ; list of tokens
  (format nil "~{~A~}"
	  (mapcar (lambda (x)
		 (if (member x '(sel/asm::qword
				 sel/asm::dword
				 sel/asm::word
				 sel/asm::byte))
		     (format nil "~A " x)
		     x))
		  op)))

(defun update-asm-line-info-text (asm-line)
  "Update the TEXT field of ASM-LINE-INFO after updated operation or operands."
  (when (eq (asm-line-info-type asm-line) ':op)
    (setf (asm-line-info-text asm-line)
	(format nil "~A ~{~A~^, ~}"
		(asm-line-info-opcode asm-line)
		(mapcar 'format-asm-operand
			(asm-line-info-operands asm-line))))))


;;; asm-heap software objects
;;
;; An software object which uses less memory. The
;; line-heap holds the original lines of the program (before any
;; mutations, along with any new or modified lines appended to the end
;; of the heap. All elements of the genome are references into this
;; line-heap.  history is a list of asm-edit structs, representing the
;; edit history. The first item in the list is the newest edit.
;;
;;
(define-software asm-heap (asm)
  ((line-heap :initarg :line-heap :accessor line-heap)
   (function-index :initarg :function-index :initform nil
		   :accessor function-index
		   :documentation "Create this on demand.")
   (function-bounds-file
    :initarg :function-bounds-file
    :initform nil :accessor function-bounds-file
    :documentation "If this is present, use it to create function index")
   (super-owner :initarg :super-owner :accessor super-owner :initform nil
		:documentation
		"If present, contains asm-super-mutant instance."))
  (:documentation
   "Alternative to SIMPLE software objects which should use less memory.
Similar to RANGE, but allows for adding and mutating lines, and should
be able to handle type of mutation we need. The GENOME is a vector of
references into the asm-heap (asm-line-info) describes the code."))

(defmethod create-super ((variant asm-heap) &optional rest-variants)
  "Creates a ASM-SUPER-MUTANT and populates it with single variant."
  (let ((inst (copy (super-owner variant))))
    (setf (mutants inst)(cons variant rest-variants))
    inst))

(defmethod function-index ((asm asm-heap))
  "If FUNCTION-INDEX slot contains an index, return it. Otherwise create
the index and return it."
  (or (slot-value asm 'function-index)
      (setf (slot-value asm 'function-index)
	    (if (function-bounds-file asm)
		(load-function-bounds asm (function-bounds-file asm))
		(create-asm-function-index asm)))))

(defmethod size ((asm asm-heap))
  "Return the number of lines in the program."
  (length (genome asm)))

(defun line-heap-copy (heap)
  (let ((new (make-array (length heap) :fill-pointer (length heap)
			 :adjustable t :initial-contents heap)))
    new))

(defmethod lines ((asm asm-heap))
  "Return the list of text lines of the genome."
  (map 'list 'asm-line-info-text (genome asm)))

(defmethod (setf lines) (asm-lines (asm asm-heap))
  "Initializes the line-heap.
Does this by converting the passed list of lines to ASM-LINE-INFO
structs, and storing them in a vector on the LINE-HEAP"
  (let* ((asm-infos '())
	 (orig-line 0)
	 (id 0))
    (dolist (line asm-lines)
      (dolist (asm-info (parse-asm-line line))
	(setf (asm-line-info-id asm-info) id)
	(setf (asm-line-info-orig-line asm-info) orig-line)
	(incf id)
	(push asm-info asm-infos))
      (incf orig-line))
    (setf asm-infos (nreverse asm-infos))
    (let* ((size (length asm-infos))
	   (heap (make-array size
                             :fill-pointer size :adjustable t
                             :initial-contents asm-infos)))
      (setf (line-heap asm) heap)
      ;; Make a copy for this instance.
      (setf (genome asm)(line-heap-copy heap))))
  ;; Create and cache function index.
  asm)

(defmethod from-file ((asm asm-heap) file)
  "Initialize an `asm-heap' software object from a file."
  (setf (lines asm) (split-sequence #\Newline (file-to-string file)))
  ;; tag all the heap entries with the original file name
  (map nil (lambda (info) (setf (asm-line-info-orig-file info) file))
       (line-heap asm))
  asm)

(defmethod to-file ((asm asm-heap) file)
  "Save the assembly for ASM to FILE."
  (with-open-file (out file :direction :output :if-exists :supersede)
    (genome-string asm out)))

(defun vector-cut (a index)
  "Destructively remove and return an element from a vector with a fill pointer."
  (let ((deleted (aref a index)))
    (do ((i index (+ i 1)))
	((= i (- (length a) 1))(decf (fill-pointer a)))
      (setf (aref a i)(aref a (+ i 1))))
    deleted))

(defun vector-insert (a index val)
  "Destructively insert and return an object into a vector with a fill pointer."
  (vector-push-extend 0 a) ; Increase size by 1 (will be resized if necessary).
  (do ((i (- (length a) 1) (- i 1)))
      ((= i index)(setf (aref a i) val))
    (setf (aref a i)(aref a (- i 1)))))

;;;
;;; Given a textual line of assembler, parse it and add the resulting
;;; list of asm-line-info structs to the heap.
;;; Returns the list of new asm-line-info struct.
;;;
(defun parse-and-add-to-heap (asm-heap text)
  (let* ((info-list (parse-asm-line text))
	 (id (length (line-heap asm-heap))))
    (dolist (info info-list)
      (setf (asm-line-info-id info) id)
      (incf id)
      (vector-push-extend info (line-heap asm-heap)))
    info-list))

;;;
;;; Parses a new line of assembler, adds it to the heap, and inserts
;;; it at index in the genome. Returns the number of lines inserted.
;;;
(defun insert-new-line (asm-heap text index)
  (let ((info-list (parse-and-add-to-heap asm-heap text)))
    (dolist (info info-list)
      (vector-insert (genome asm-heap) index info)
      (incf index))
    (length info-list)))

;;;
;;; Parse and add a list of lines of assembler code.
;;;
(defun insert-new-lines (asm-heap line-list index)
  (dolist (x line-list)
    (incf index (insert-new-line asm-heap x index))))

(defmethod pick-good ((software asm-heap))
  (pick-bad software))

(defun pick-is-acceptable (asm n)
  (if (asm-line-info-label (elt (genome asm) n))
      nil   ;; don't mess with label lines
      t))

;;;
;;; TO DO: this can go into an infinite loop if every line in the
;;; genome is a label declaration. Should probably watch for this case.
;;;
(defmethod pick-bad  ((software asm-heap))
  (do* ((bad (random (size software))(random (size software))))
       ((pick-is-acceptable software bad) bad)))

(defmethod apply-mutation ((asm asm-heap) (mutation simple-cut))
  "Implement simple-cut mutation on ASM-HEAP."
  ;; if we our target cut is a label line, abort
  (when (and
	 (asm-line-info-label (elt (genome asm) (targets mutation)))
	 (find-restart 'try-another-mutation))
    (format t "skipping cut with label ~A~%"
	    (asm-line-info-label (elt (genome asm) (targets mutation))))
    (invoke-restart 'try-another-mutation))
  (vector-cut (genome asm) (targets mutation))
  asm)

(defmethod apply-mutation ((asm asm-heap) (mutation simple-insert))
  "Insert a value into location of ASM as specified by MUTATION."
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    (vector-insert (genome asm)
                   (first bad-good)
                   (aref (genome asm) (second bad-good))))
  asm)

(defmethod apply-mutation ((asm asm-heap) (mutation simple-swap))
  "Swap the values at two locations in ASM as specified by MUTATION."
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    (with-slots (genome) asm
      (rotatef (aref genome (first bad-good)) (aref genome (second bad-good))))
    asm))

(defun asm-heap-subseq (asm start &optional end)
  "Create a new mutated asm-heap.
The new genome contains only the elements in the designated range."
  (let* ((new (copy asm))
	 (genome (genome new))
	 (new-genome (line-heap-copy (subseq genome start end))))
    (setf (genome new) new-genome)
    new))

(defmethod apply-mutation ((asm asm-heap) (mutation asm-replace-operand))
  "Apply an asm-replace-operand MUTATION to ASM-HEAP, return the resulting
software. The MUTATION targets are a pair of instruction indices pointing
to a \"bad\" instruction (whose operand will be replaced) and
a \"good\" instruction (whose operand will be used as the replacement).
If either instruction lacks an operand, a `no-mutation-targets' condition
is raised."
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    ;; NOTE: assumes instructions start with :code symbol
    (let* ((genome (genome asm))
           (bad (first bad-good))
	   (good (second bad-good))
           (bad-instr (elt genome bad))
	   (good-instr (elt genome good))
           (bad-operands (asm-line-info-operands bad-instr))
           (good-operands (asm-line-info-operands good-instr)))
      (when (or (null bad-operands) (null good-operands))
        (error (make-condition 'no-mutation-targets
                               :text "No operands in instruction(s)"
                               :obj asm)))
      (let ((new-instr (copy-asm-line-info bad-instr)))
	;; update one of the operands with a randomly selected operand from
	;; the good statement
	(setf (elt (asm-line-info-operands new-instr)
		   (random (length (asm-line-info-operands new-instr))))
	      (random-elt good-operands))
	;; update the text since we changed the operand
	(update-asm-line-info-text new-instr)
	;; update the genome with the newly modified instruction
        (setf (elt genome bad) new-instr)
        asm))))

(defmethod pick-mutation-type ((asm asm-heap))
  (random-pick *simple-mutation-types*))

(defun find-labels (asm-heap)
  (let ((lab-list '()))
    (iter (for a in-vector (genome asm-heap))
	  (if (and
	       (eq (asm-line-info-type a) ':op)
	       (branch-op-p (first (asm-line-info-tokens a))))
	    (if (token-label-p (second (asm-line-info-tokens a)))
		(push (second (asm-line-info-tokens a)) lab-list))
	    (if (token-label-p (third (asm-line-info-tokens a)))
		(push (third (asm-line-info-tokens a)) lab-list))))
    lab-list))

(defun find-label-decls (asm-heap)
  "Find the labels declared in the genome, return the list."
  (let ((lab-list '()))
    (iter (for a in-vector (genome asm-heap))
	  (if (eq (asm-line-info-type a) ':label-decl)
	      (push (asm-line-info-label a) lab-list)))
    lab-list))

(defun labels-valid-p (asm-heap)
  "Returns true if all labels which are referenced by
operation lines in the genome can be found as label declarations
in the genome. There must be no more than one declaration of any
label. If any referenced label is not found, or is declared more
than once, returns false."
  (dolist (lab (find-labels asm-heap))
    (let ((count 0))
      (iter (for a in-vector (genome asm-heap))
	    (if (eq (asm-line-info-label a) lab)
		(incf count)))
      (unless (= count 1) (return-from labels-valid-p nil))))
  ;; return false if any of the label declarations are duplicated
  (let ((declared-labels (find-label-decls asm-heap)))
    (= (length declared-labels) (length (remove-duplicates declared-labels)))))

;;;
;;; Issues with the searching method below. I think we we might get reasonable
;;; results simply by using the same point in both genomes. In case the
;;; point exceeds the size of b's genome, we truncate it to the largest
;;; possible point in b.
;;;
;;; TODO: figure out the best approach to implement this method
;;;
(defmethod find-corresponding-point ((point-a integer) (a asm-heap) (b asm-heap))
  "Find and return a point in asm B matching POINT-A in asm A.
Used by `homologous-crossover'."
  (if (>= point-a (size b))
      (1- (size b))
      point-a))

#+ignore
(defmethod find-corresponding-point ((point-a integer) (a asm-heap) (b asm-heap))
  "Find and return a point in asm B matching POINT-A in asm A.
Used by `homologous-crossover'."
  (flet ((lookup-id (obj id)
           (asm-line-info-id (elt (genome obj) id))))
    (let* ((id-a (lookup-id a point-a))
           ;; adjust if id-a is beyond length of b
           (start (if (>= id-a (length (genome b)))
                      (1- (length (genome b)))
                      id-a))
           ;; max value we can add to start and still have a valid index in b
           (add-upper-bound (- (1- (length (genome b))) start)))
      ;; search above/below start simultaneously, adding and subtracting i
      ;; to get the indices to check (upper and lower, resp.)
      (iter (for i below (max start (1+ add-upper-bound)))
            ;; keep track of closest difference in case there's no exact match
            (with closest = start)
            (with closest-diff = (abs (- id-a (lookup-id b start))))
            (let ((lower (- start (min i start)))
                  (upper (+ start (min i add-upper-bound))))
              (cond
                ;; lower index contains an exact match
                ((eql id-a (lookup-id b lower))
                 (leave lower))
                ;; upper index contains an exact match
                ((eql id-a (lookup-id b upper))
                 (leave upper))
                ;; neither upper nor lower matches, check if either is close
                (t (when-let ((id-b-lower (lookup-id b lower)))
                     (when (> closest-diff (abs (- id-a id-b-lower)))
                       ;; id at lower is closer than closest yet found
                       (setf closest lower)
                       (setf closest-diff (abs (- id-a id-b-lower)))))
                   (when-let ((id-b-upper (lookup-id b upper)))
                     (when (> closest-diff (abs (- id-a id-b-upper)))
                       ;; id at upper is closer than closest yet found
                       (setf closest upper)
                       (setf closest-diff (abs (- id-a id-b-upper)))))))
              (finally (return closest)))))))

(defmethod homologous-crossover ((a asm-heap) (b asm-heap))
  "Crossover at a similar point in asm objects, A and B.
After picking a crossover point in A, try to find the same point in B. If A and
B are identical, this implementation always results in a genome that matches
those of A and B."
  ;; ASM-HEAP genomes are automatically numbered

  ;; if either genome is 0-length, just return the other asm-heap object
  (cond ((zerop (length (genome a))) (values (copy b) 0 0))
	((zerop (length (genome b))) (values (copy a) 0 0))
	(t
	 (let ((point-a (random (length (genome a))))
	       (new (copy a)))
	   (let* ((point-b (find-corresponding-point point-a a b))
		  (new-seq (concatenate (class-of (genome a))
					; copy from beginning to point-a in A
					(subseq (genome a) 0 point-a)
					; and from point-b to end in B
					(subseq (genome b) point-b))))
	     (setf (genome new)
		   (make-array (length new-seq) :fill-pointer (length new-seq)
			       :adjustable t :initial-contents new-seq))
	     (if (labels-valid-p new)  ; filter out any crossover results which
		                       ; messup the labels
	         (values new point-a point-b)
		 (values (copy a) 0 0)))))))

(defun function-name-from-label (name)
  "Given a label like $FOO1, returns \"FOO\""
  (subseq (symbol-name name) 1))

(defun function-label-p (label-name)
  "Returns true if the passed symbol represents a valid function name.
The heuristic is that if it starts with #\$ and doesn't start with the
known prefixes that are auto-generated in the code, we consider it a
function name."
  (let ((name (symbol-name label-name)))
    (and
     (char= (elt name 0) #\$)
     (not
      (or (starts-with-p name "$LOC_")
	  (starts-with-p name "$BB_FALLTHROUGH_")
	  (starts-with-p name "$UNK_"))))))

(defun line-is-function-label (asm-line-info)
  "Returns true if the passed line-info represents a name of a function."
  (and (asm-line-info-label asm-line-info)
       (function-label-p (asm-line-info-label asm-line-info))))

(defun extract-function-name-from-decl (decl-name)
  (let ((name (symbol-name decl-name)))
    (subseq name 1 (position #\. name))))

(defun extract-function-declarations (asm)
  "Traverse the asm-heap, and collect declarations associated with
each function. The function name is determined from the declaration.
The declarations are stored in a hash-table, keyed to the function
name. The resulting hash-table is returned."
  (let ((table (make-hash-table :test 'equalp))
	(genome (genome asm)))
    (iter (for x in-vector genome)
	  (if (eq (asm-line-info-type x) ':decl)
	      (push
	        x
	        (gethash
		 (extract-function-name-from-decl
		  (first (asm-line-info-tokens x)))
		 table))))
    table))

(defun create-asm-function-index (asm)
  "Traverse the passed asm-heap, and collect a function-index-entry
for each function. The result is a vector of function-index-entry."
  (let ((table (extract-function-declarations asm))
	(entries '())
	(i 0)
	(genome (genome asm)))
    (iter (while (< i (length genome)))
	  (let ((info (elt genome i)))
	    (if (line-is-function-label info)
		;; look for the end of the function
		(let ((start-index i)
		      (name (function-name-from-label
			     (asm-line-info-label info)))
		      (leaf t))
		  (incf i)
		  (iter (while (< i (length genome)))
			(let ((info2 (elt genome i)))
			  (if (eq (asm-line-info-opcode info2)
				  'sel/asm::call)
			      (setf leaf nil)) ;found a call, so not a leaf
			  (when (or
				 (eq (asm-line-info-opcode info2)
				     'sel/asm::ret)
				 (and
				  (eq (asm-line-info-type info2)
				      :decl)
				  (eq (first (asm-line-info-tokens info2))
				      'sel/asm::align))
				 (line-is-function-label info2))
			    (push
			     (make-function-index-entry
			      :name name
			      :start-line start-index
			      :start-address (asm-line-info-address info)
			      :end-line i
			      :end-address (asm-line-info-address info2)
			      :is-leaf leaf
			      :declarations (gethash name table)) entries)
			    (return)))
			(incf i)))))
	  (incf i))
    (setf entries
	  (remove-if (lambda (x)
		       (or (null (function-index-entry-start-address x))
			   (null (function-index-entry-end-address x))))
		     (nreverse entries)))
    (make-array (length entries) :initial-contents entries)))

(defun asm-labels (asm)
  "Return a hashtable of the labels in the asm-heap"
  (let ((ht (make-hash-table :test 'equalp)))
      (iter (for x in-vector (genome asm))
	    (and (asm-line-info-label x)
		 (setf (gethash
			(function-name-from-label (asm-line-info-label x))
			ht) t)))
      ht))

(defgeneric load-function-bounds (software-obj file)
  (:documentation
   "Load function boundaries into FUNCTION-BOUNDS for OBJ from FILE.")
  (:method ((asm asm-heap) file)
    (flet ((get-hex-val (s)
             (when (starts-with-subseq "0x" s)
               (values (parse-integer s :start 2 :radix 16))))
           (index-of-addr (asm addr)
             ;; Return the line index (0-based) of the line of the
             ;; genome which matches the passed address.
             (position addr (genome asm)
                       :test 'eql :key 'asm-line-info-address)))
      (when (probe-file file)
        (let ((valid-fn-labels (asm-labels asm))
	      (entries '())
	      (table (extract-function-declarations asm)))
          (with-open-file (in file)
            (iter (for line = (read-line in nil))
                  (while line)
                  ;; Line is formatted:
                  ;; fn-name start-ea end-ea leaf-or-non-leaf
                  (let ((split-line (split "\\s+" line)))
                    (when (>= (length split-line) 4)
                      (let ((fn-name (first split-line))
                            (start-ea (second split-line))
                            (end-ea (third split-line)))
                        ;; Check valid start/end EAs
                        (when (and (not (string= "BADEA" start-ea))
                                   (not (string= "BADEA" end-ea))
                                   ;; Only keep functions matching labels in OBJ
                                   (gethash fn-name valid-fn-labels))
		          (let ((start-addr (get-hex-val start-ea))
			        (end-addr (get-hex-val end-ea)))
			    (push
			     (make-function-index-entry
			      :name fn-name
			      :start-line (index-of-addr asm start-addr)
			      :start-address start-addr
			      :end-line (index-of-addr asm end-addr)
			      :end-address end-addr
			      :is-leaf (string= "leaf" (fourth split-line))
			      :declarations (gethash fn-name table))
			     entries))))))))
          (setf entries (remove-if
		         (lambda (x)
		           (or (null (function-index-entry-start-address x))
			       (null (function-index-entry-end-address x))))
		         (nreverse entries)))
          (make-array (length entries) :initial-contents entries))))))

#|
   Not implemented yet --RGC

(defmethod one-point-crossover ((a sw-range) (b sw-range))
  "DOCFIXME"
  (assert (eq (reference a) (reference b)) (a b)
          "Can not crossover range objects with unequal references.")
  (let ((range (min (size a) (size b))))
    (if (> range 0)
        (let ((point (random range))
              (new (copy a)))
          (setf (genome new)
                (copy-seq (append (range-subseq (genome a) 0 point)
                                  (range-subseq (genome b) point))))
          (values new point))
        (values (copy a) 0))))

(defmethod two-point-crossover ((a sw-range) (b sw-range))
  "DOCFIXME"
  (let ((range (min (size a) (size b))))
    (if (> range 0)
        (let ((points (sort (loop :for i :below 2 :collect (random range)) #'<))
              (new (copy a)))
          (setf (genome new)
                (copy-seq
                 (append
                  (range-subseq (genome b) 0 (first points))
                  (range-subseq (genome a) (first points) (second points))
                  (range-subseq (genome b) (second points)))))
          (values new points))        (values (copy a) nil))))

(setf *orig* (from-file (make-instance
                   'asm-heap)
                  (make-pathname
                   :name "calc.null"
                   :type "asm"
                   :directory "/u1/rcorman/synth/shaker/test/etc/calc/GTX.FILES")))

(dotimes (i (length g))
  (let ((info (elt g i)))
    (if (and (asm-line-info-label info)
             (not (starts-with-p (symbol-name (asm-line-info-label info)) "$LOC_"))
	     (not (starts-with-p (symbol-name (asm-line-info-label info)) "$BB_FALLTHROUGH_"))
             (not (starts-with-p (symbol-name (asm-line-info-label info)) "$UNK_")))
      (format t "~A ~A ~A~%"
        (first (asm-line-info-tokens info))
        (asm-line-info-orig-line info)
        (asm-line-info-text info)))))
|#
