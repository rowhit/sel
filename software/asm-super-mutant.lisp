;;;;
;;;; asm-super-mutant.lisp --- combine super-mutant functionalities
;;;; with asm-heap
;;;;

(in-package :software-evolution-library)
(in-readtable :curry-compose-reader-macros)

;;; asm-super-mutant software objects
;;; This will consist of an asm-heap, which is based on a file of assembly
;;; source code, and input/output specifications, as well as a function
;;; boundary deliminator which determines the target of the mutation algorithm.
;;;
;;;
(define-software asm-super-mutant (asm-heap super-mutant)
  ((input-spec :initarg :input-spec :accessor input-spec)
   (output-spec :initarg :output-spec :accessor output-spec))
  (:documentation
   "Combine super-mutant capabilities with asm-heap framework."))

;;;
;;; all the SIMD register names start with 'y'
;;;
(defun simd-reg-p (name) (char= (elt name 0) #\y))

(defstruct memory-spec
  addr   ; 64-bit address as an int
  mask   ; bit set for each live byte starting at addr,
					; low-bit (bit 0) = addr,
                                        ; bit 1 = addr+1, etc.
  bytes) ; 8 bytes starting at addr

(defun bytes-to-string (ba)
  (format nil "~{ ~2,'0X~}" (concatenate 'list ba)))

(defmethod print-object ((mem memory-spec) stream)
  (Format stream "~16,'0X: ~T~A ~A"
	  (memory-spec-addr mem)
	  (Memory-spec-mask mem)
	  (bytes-to-string (memory-spec-bytes mem))))

(defstruct reg-contents
  name     ; name of register (string) i.e. "rax", "ymm1", etc.
  value)   ; integer value (64 bits for gen. purpose, 256 bit for SIMD)

(defmethod print-object ((reg reg-contents) stream)
  (if (simd-reg-p (reg-contents-name reg))
      (format stream "~4A: ~A" (reg-contents-name reg)
	      (bytes-to-string (reg-contents-value reg)))
      (format t "~4A: ~A" (reg-contents-name reg)
	      (bytes-to-string (reg-contents-value reg)))))

;;;
;;; This struct also is used to specify outputs.
;;;
(defstruct input-specification
  regs
  simd-regs 
  mem)   ;; vector of memory-spec to indicate all memory inputs

(defmethod print-object ((spec input-specification) stream)
  (iter (for reg in-vector (input-specification-regs spec))
	(print reg))
  (iter (for reg in-vector (input-specification-simd-regs spec))
	(print reg))
  (iter (for mem in-vector (input-specification-mem spec))
	(print mem)))

#|
Jonathan's comments about the format:

The format I'm about to describe is in ASCII, which I've found can make it 
easier to debug and understand the code generated by the search. Basically, we 
just specify the values of all registers, one per line, followed by the 
values of relevant memory addresses.

Each line describing a register would contain the name of the register, 
followed by the bytes in big-endian order. The register would be separated 
from the bytes by whitespace, but any other whitespace on the line would 
be purely cosmetic (to make it easier for humans to process) and should 
be ignored. For example, the line,

%rax    00 00 00 00 00 00 01 00

indicates that register rax should contain the value 256. For the 
general-purpose registers rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, 
r10, r11, r12, r13, r14, and r15, all eight bytes will be explicitly 
included on the line. For the SIMD registers ymm0-ymm15, all 32 bytes 
will be explicit.

Memory would be specified with one 8-byte long per line, consisting of
an address, followed by a mask indicating which bytes are live, followed 
by the bytes themselves. The mask would be separated from the address and 
bytes by whitespace, but again any other whitespace on the line should be 
ignored. For example, the line,

00007fbb c1fcf768   v v v v v v v .   2f 04 9c d8 3b 95 7c 00

indicates that the byte at address 0x7fbbc1fcf768 has value 0x2f, 
the byte at 0x7fbbc1fcf769 has value 0x04, and so forth. Note that bytes 
0x7fbbc1fcf768-0x7fbbc1fcf76e are live (indicated with "v") while 
0x7fbbc1fcf76f is not (indicated with ".").
|#

;;; whitespace handling
;;;
(defun is-whitespace (c)
  (member c '(#\space #\linefeed #\newline #\tab #\page)))

(defun get-next-line (input)
  (let ((line (read-line input nil 'eof)))
    (if (stringp line)
	(trim-whitespace line))))  ;; returns nil if end-of-file

;;;
;;; The string argument should consist only of hex digits (at least in the first
;;; num * 2 characters). The number argument is the number of bytes to parse.
;;; Returns a byte array.
;;;
(defun parse-bytes (num str)
  (let ((result (make-array num :element-type '(unsigned-byte 8))))
    (dotimes (i num)
      (setf (aref result i)
	    (+ (* (digit-char-p (char str (* i 2)) #x10) #x10)
	       (digit-char-p (char str (+ 1 (* i 2))) #x10))))
    result))


;;;
;;; Returns a 64-bit integer representing an address, and the line position
;;; immediately following the address. The address should be in the format:
;;;   xxxxxxxx xxxxxxxx
;;; (16 hex digits, with 8 digits + space + 8 digits = 17 chars)
;;;;
(defun parse-address (line pos)
  (let ((result 0))
    (dotimes (i 8)
      (setf result (+ (* result #x10)
		      (digit-char-p (char line (+ i pos)) #x10))))
    (dotimes (i 8)
      (setf result (+ (* result #x10)
		      (digit-char-p (char line (+ i 9 pos)) #x10))))
    (values result (+ pos 17))))

(defun parse-mem-spec (line pos)
  (multiple-value-bind (addr i)
      (parse-address line pos)
    (setf pos i)
    (iter (while (is-whitespace (char line pos))) (incf pos)) ; skip spaces
    (let ((b (make-array 8 :element-type 'bit)))
      (dotimes (i 8)
	(setf (bit b i)
	      (if (char= (char line pos) #\v) 1 0))
	(incf pos 2))
      (make-memory-spec :addr addr
			:mask b
			:bytes (parse-bytes 8
					    (remove #\space
						    (subseq line pos))))))) 

(defun parse-reg-spec (line pos)
  (let ((name               ; get the register name (string)
	 (do ((c (char line (incf pos))(char line (incf pos)))
	      (chars '()))
	     ((is-whitespace c)
	      (concatenate 'string (nreverse chars)))
	   (push c chars))))
    (if (simd-reg-p name)  ; was it a SIMD register?
        (make-reg-contents
	 :name name
	 :value (parse-bytes 32
			     (remove #\space (subseq line pos))))
	;; else a general-purpose register
	(make-reg-contents
	 :name name
	 :value (parse-bytes 8
			     (remove #\space (subseq line pos)))))))


(defun load-io-file (super-asm filename)
  "Load the file containing input and output state information"
  (let ((input-spec (make-input-specification
		     :regs (make-array 16 :fill-pointer 0)
		     :simd-regs (make-array 16 :fill-pointer 0)
		     :mem (make-array 0 :fill-pointer 0 :adjustable t)))
	(output-spec (make-input-specification
		     :regs (make-array 16 :fill-pointer 0)
		     :simd-regs (make-array 16 :fill-pointer 0)
		     :mem (make-array 0 :fill-pointer 0 :adjustable t)))
	(parsing-inputs t))
    (with-open-file (input filename :direction :input)
      (do ((line (get-next-line input) (get-next-line input))
	   (pos 0 0))
	  ((null line))
	(cond ((zerop (length line))) ; do nothing, empty line
	      ((search "Input data" line) (setf parsing-inputs t))
	      ((search "Output data" line)(setf parsing-inputs nil))
	      ((char= (char line 0) #\%) ; register spec?
	       (let ((spec (parse-reg-spec line pos)))
		 (if (simd-reg-p (reg-contents-name spec))  ; SIMD register?
		     (vector-push
		       spec
		       (input-specification-simd-regs
		       (if parsing-inputs input-spec output-spec)))
		     ;; else a general-purpose register
		     (vector-push
		       spec
		       (input-specification-regs
		         (if parsing-inputs input-spec output-spec))))))
	      (t ; assume memory specification
	       (vector-push-extend
		 (parse-mem-spec line pos)
		   (input-specification-mem
		    (if parsing-inputs input-spec output-spec)))))))
    (setf (input-spec super-asm) input-spec)
    (setf (output-spec super-asm) output-spec))
  t)

;;;
;;; takes 8 bit mask and converts to 8-byte mask, with each
;;; 1-bit converted to 0xff to mask a full byte.
;;;
(defun create-byte-mask (bit-mask)
  (map 'vector (lambda (x)(if (zerop x) #x00 #xff)) bit-mask))

;;;
;;; assume bytes are in little-endian order
;;;
(defun bytes-to-qword (bytes)
  (let ((result 0))
    (iter (for i from 7 downto 0)
	  (setf result (+ (ash result 8) (aref bytes i))))
    result))

;;;
;;; Assume bytes are in big-endian order
;;;
(defun be-bytes-to-qword (bytes)
  (let ((result 0))
    (iter (for i from 0 to 7)
	  (setf result (+ (ash result 8) (aref bytes i))))
    result))

;;;
;;; reg is a string, naming the register i.e. "rax" or "r13".
;;; bytes is an 8-element byte array containing the 64-bit unsigned contents
;;; to be stored, in big-endian order
;;;
(defun load-reg (reg bytes)
  (format nil "mov qword ~A, 0x~X"
	  reg
	  (be-bytes-to-qword bytes)))

;;;
;;; reg is a string, naming the register i.e. "rax" or "r13".
;;; bytes is an 8-element byte array containing the 64-bit unsigned contents
;;; to be compared, in big-endian order
;;;
(defun comp-reg (reg bytes)
  (let ((label (gensym "reg-cmp-")))
    (list
      (format nil "push ~A" reg)
      (format nil "mov qword ~A, 0x~X"
	  reg
	  (be-bytes-to-qword bytes))
      (format nil "cmp qword ~A, [rsp]" reg)
      (format nil "pop ~A" reg)
      (format nil "je ~A" label)
      (format nil
	  "mov rdi, \"Comparison of register ~A failed: expected 0x~X\""
	  reg 
          (be-bytes-to-qword bytes))
      (format nil "jmp output_comparison_failure")
      (format nil "~A:" label))))
  

;;;
;;; Initialize 8 bytes of memory, using the mask to init only specified bytes.
;;; Returns list of lines to do the initialization.
;;;
(defun init-mem (spec)
  (let ((addr (memory-spec-addr spec))
	(mask (memory-spec-mask spec))
	(bytes (memory-spec-bytes spec)))
    (if (equal mask #*11111111)  ;; we can ignore the mask
      (list
        (format nil "mov qword rax, 0x~X" (bytes-to-qword bytes))
        (format nil "mov qword rcx, 0x~X" addr)
        "mov qword [rcx], rax")	
      (list
        (format nil "mov qword rax, 0x~X" (bytes-to-qword bytes))
        (format nil "mov qword rbx, 0x~X"
		(bytes-to-qword (create-byte-mask mask)))
        (format nil "mov qword rcx, 0x~X" addr)
        "and rax, rbx"   ; mask off unwanted bytes of src
        "not rbx"        ; invert mask
        "and qword [rcx], rbx" ; mask off bytes which will be overwritten
        "or qword [rcx], rax"))))

;;;
;;; Initialize 8 bytes of memory, using the mask to init only specified bytes.
;;; Returns list of lines to do the initialization.
;;;
(defun comp-mem (spec)
  (let ((addr (memory-spec-addr spec))
	(mask (memory-spec-mask spec))
	(bytes (memory-spec-bytes spec))
	(label (gensym "mem-cmp-")))
    (if (equal mask #*11111111)  ;; we can ignore the mask
	(list
	 (format nil "mov qword rax, 0x~X" (bytes-to-qword bytes))
	 (format nil "mov qword rcx, 0x~X" addr)
	 "cmp qword [rcx], rax"
	 (format nil "je ~A" label)
         (format nil
	   "mov rdi, \"Comparison of address 0x~X failed: expected 0x~X\""
	   addr 
           (bytes-to-qword bytes))
         (format nil "jmp output_comparison_failure")
         (format nil "~A:" label))
	(list
	 (format nil "mov qword rax, 0x~X" (bytes-to-qword bytes))
	 (format nil "mov qword rbx, 0x~X" (bytes-to-qword (create-byte-mask mask)))
	 (format nil "mov qword rcx, 0x~X" addr)
	 "mov qword rcx, [rcx]"
	 "and rax, rbx"   ; mask off unwanted bytes of src
	 "and rcx, rbx" ; mask off unwanted bytes of dest
	 "cmp rcx, rax"
	 (format nil "je ~A" label)
         (format nil
	   "mov rdi, \"Comparison of address 0x~X failed: expected 0x~X\""
	   addr 
           (bytes-to-qword bytes))
         (format nil "jmp output_comparison_failure")
         (format nil "~A:" label)))))

;;;
;;; Return asm-heap containing the lines to set up the environment
;;; for a fitness test.
;;; Skip SIMD registers for now.
;;;
(defun init-env (asm-super)
  (let* ((input-spec (input-spec asm-super))
	 (reg-lines
	  (iterate
	    (for x in-vector (input-specification-regs input-spec))
	    (collect (load-reg (reg-contents-name x)(reg-contents-value x)))))
	 (mem-lines
	  (apply 'append
		 (iterate
	           (for x in-vector (input-specification-mem input-spec))
		   (collect (init-mem x)))))
	 (asm (make-instance 'asm-heap)))
    (setf (lines asm) (append mem-lines reg-lines))
    asm))

;;;
;;; Return an asm-heap containing the lines to check the resulting outputs.
;;; Skip SIMD registers for now.
;;;
(defun check-env (asm-super)
  (let* ((output-spec (output-spec asm-super))
	 (reg-lines
	  (apply 'append
		 (iterate
	           (for x in-vector (input-specification-regs output-spec))
	           (collect
		       (comp-reg (reg-contents-name x)(reg-contents-value x))))))
	 (mem-lines
	  (apply 'append
		 (iterate
	           (for x in-vector (input-specification-mem output-spec))
		   (collect (comp-mem x)))))
	 (asm (make-instance 'asm-heap)))
    (setf (lines asm) (append reg-lines mem-lines))
    asm))

#|
(defvar *asm-super* (make-instance 'asm-super-mutant))
(load-io-file *asm-super* 
  "/u1/rcorman/synth/sel/test/etc/asm-test/grep-io.txt") 
(setf *heap* (init-env *asm-super*))
|#
