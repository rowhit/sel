;;; asm-super-mutant.lisp --- SUPER-MUTANT for single assembly functions
;;;
;;; @subsection ASM-SUPER-MUTANT Overview
;;;
;;; ASM-SUPER-MUTANT software objects are designed to provide the
;;; benefits of SUPER-MUTANT to assembly programs.  Its primary
;;; advantage is the ability to evaluate the fitness of large numbers
;;; of variants of a given target function, in a single process, in a
;;; minimal amount of time.  Avoiding the per-process overhead in
;;; fitness evaluations results in orders-of-magnitude improvements of
;;; efficiency.
;;;
;;; The ASM-SUPER-MUTANT is an ASM-HEAP represents assembler (possibly
;;; lifted from a binary executable e.g., by GrammaTech's CodeSurfer
;;; for Binaries) and also contains the SUPER-MUTANT methods.
;;;
;;; The ASM-SUPER-MUTANT initially contains a complete program
;;; executable (initialized from an asm format file).  In addition it
;;; contains a specification of a target function within the overall
;;; program.  The target function (specified either by name or as
;;; start and end addresses) is used to mark a range of lines within
;;; the overall program (returned by CREATE-TARGET).
;;;
;;; Like a SUPER-MUTANT, the ASM-SUPER-MUTANT maintains a collection
;;; of MUTANTS, each one being an instance of the ASM-HEAP software
;;; object.  Each MUTANT is a variant of the target function.
;;;
;;; @subsection Fitness Evaluation
;;;
;;; To perform fitness evaluation, the ASM-SUPERMUTANT performs the
;;; following steps:
;;;
;;; * The MUTANTS are combined into a single assembly file (.asm),
;;;   which also includes the data sections and declarations necessary
;;;   to be able to assemble. Every MUTANT is given a unique label
;;;   (variant_0, (variant_1, ... variant_n), and those labels are
;;;   exported.
;;;
;;; * Input/output data, see @pxref{i-o-file-format, I/O File Format},
;;;   is appended to the asm file, and is used to determine fitness of
;;;   each variant.  A set of I/O data (memory and register contents)
;;;   is provided for each test run of the target function.
;;;
;;; * The .asm file is assembled with NASM.
;;;
;;; * A C harness file (asm-super-mutant-fitness.c), which runs and
;;;   evaluates variants, is compiled and linked to the compiled
;;;   object file.  The C code provides functions to set up each test,
;;;   execute each variant, calculate the variant's fitness and
;;;   aggregate results.  Currently the fitness is set to the number
;;;   of executed instructions as collected by the linux Performance
;;;   Application Programming Interface (PAPI)
;;;   (@url{http://icl.utk.edu/papi/}) using the PAPI_TOT_INS event.
;;;   The harness contains some sandboxing code to handle differences
;;;   in execution address of the original test runs and the fitness
;;;   runs, manage heap memory pages, and trap and handle segment
;;;   violations and function crashes.
;;;
;;; * Each variant is assigned an array of fitness results, with each
;;;   item in in the array representing the number of instructions
;;;   required to execute the function on a given test run (i.e., I/O
;;;   pair).  If the variant did not properly pass the tests (I/O data
;;;   did not match) then MAXINT is assigned as the fitness variable
;;;   for that test run (since smaller is better, this is the worst
;;;   possible fitness).
;;;
;;; * The fitness harness writes an array of all test results for all
;;;   variants to the *STANDARD-OUTPUT* stream.
;;;
;;; * The compiled/linked fitness executable is executed by the
;;;   fitness test and the results (written to *STANDARD-OUTPUT*) are
;;;   parsed and stored in Lisp data structures (as an array of
;;;   arrays). This is cached on the ASM-SUPER-MUTANT instance, and
;;;   can be obtained with the FITNESS method.
;;;
;;; @subsection Tool Dependencies
;;;
;;; The ASM-SUPER-MUTANT currently depends upon:
;;; * Nasm to assemble the generated fitness program
;;; * Clang (version 6 or later) to compile and link the fitness program.
;;; * Assembly code or a high quality lifter (e.g., GrammaTech's
;;;   CodeSurfer for Binaries) to disassemble an original binary
;;;   program.
;;; * A method of collecting binary I/O pairs from a series of dynamic
;;;   tests in the format described below,
;;;   @pxref{i-o-file-format, I/O File Format}
;;;
;;; The ASM-HEAP, which is the basis for ASM-SUPER-MUTANT and all its
;;; variants, uses Intel-format assembly code (Nasm-compatible).
;;; In the near future we are planning to switch to AT&T assembler syntax
;;; and to replace Nasm with a more efficient assembler.
;;;
;;; @anchor{i-o-file-format}
;;; @subsection I/O File Format
;;;
;;; The file is ASCII.  In internal tests it s generated using the IBM
;;; PIN tool to observe the execution of a binary program on a test
;;; suite.
;;;
;;; An I/O file contains 1 or more test runs, and each test run
;;; comprises 2 sections: Input Data and Output Data.
;;;
;;; The format of Input Data is identical to Output Data, except that
;;; the set of registers that are included may differ.
;;;
;;; Each section (Input Data or Output Data) contains a section of
;;; register lines, followed by a section of memory lines.
;;;
;;; In the register section, the values of all significant registers
;;; are specified, one per line. This includes general-purpose
;;; registers (GPR) i.e. rax rbx, etc. followed by floating-point
;;; registers ymm0-15.
;;;
;;; Following the registers are values of relevant memory
;;; addresses. These include any memory addresses read or written by
;;; the function being tested.  If the function depends on a global
;;; variable for instance, it will be included.
;;;
;;; In the first section (registers) each line contains:
;;; * The name of the register, followed by the bytes in big-endian order,
;;; * The register name is separated from the bytes by whitespace, but any
;;;   other whitespace on the line should be ignored.
;;;
;;; For example, the line,
;;;
;;;     %rax    00 00 00 00 00 00 01 00
;;;
;;; indicates that register rax should contain the value 256.
;;;
;;; For the general-purpose registers rax, rcx, rdx, rbx, rsp, rbp,
;;; rsi, rdi, r8, r9, r10, r11, r12, r13, r14, and r15, all eight
;;; bytes will be explicitly included on the line.  For the SIMD
;;; registers ymm0-ymm15, all 32 bytes will be explicit.
;;;
;;; Memory would be specified with one 8-byte long per line, in
;;; big-endian order, consisting of an address, followed by a mask
;;; indicating which bytes are live, followed by the bytes
;;; themselves. The mask would be separated from the address and bytes
;;; by whitespace, but again any other whitespace on the line should
;;; be ignored.
;;;
;;; For example, the line,
;;;
;;;     00007fbb c1fcf768   v v v v v v v .   2f 04 9c d8 3b 95 7c 00
;;;
;;; indicates that the byte at address 0x7fbbc1fcf768 has value 0x00,
;;; the byte at 0x7fbbc1fcf769 has value 0x7c, and so forth
;;; (big-endian order).  Note that bytes 0x7fbbc1fcf769-0x7fbbc1fcf76f
;;; are live (indicated with "v") while 0x7fbbc1fcf768 is not
;;; (indicated with ".").
;;;
;;; @subsection Components
;;;
;;; ASM-SUPER-MUTANT software object consists of:
;;;
;;; * The ASM-HEAP, which is typically based on a file of assembly
;;;   source code.  The ASM-SUPER-MUTANT object contains the whole original
;;;   binary application (in assembler source format).
;;;
;;; * Input/output specifications, in a specific file format as
;;;   generated using the Intel monitoring application and our Python
;;;   scripts
;;;
;;; * Data object original addresses ("sanity file").
;;;
;;; * Function boundary deliminators which determines the target of
;;;   the mutation and evaluation.
;;;
;;; Note that the struct INPUT-SPECIFICATION is a bit of a misnomer as
;;; it is used here for both input specification and output
;;; specification (their formats are identical so we use the same
;;; struct for both).
;;;
;;; SUPER-MUTANT slots:
;;; * MUTANTS will contain a list of ASM-HEAP objects.
;;; * SUPER-SOFT caches a combined ASM-HEAP representing the output
;;;   fitness program.
;;; * PHENOME-RESULTS caches the results obtained from calling the PHENOME
;;;   method.
;;;
;;; @subsection Current Limitations
;;;
;;; * Functions which use floating point data as input or outputs will
;;;   not evaluate correctly. The fitness file that is generated does
;;;   not yet handle @code{ymm0}-@code{ymm15} registers, which are used to
;;;   pass floating point values in x86_64 binaries.
;;; * Currently only leaf functions (functions which do not call any other
;;;   functions) are supported.
;;; * The fitness test program does not do full sandboxing. It does protect
;;;   against segment violations (those will typically result in a
;;;   +worst-c-fitness+ rating) but a function variant could potentially write
;;;   on other code or data without triggering a segment violation, and this
;;;   will not get trapped. When that happens it will possibly invalidate
;;;   further fitness tests, or cause the whole fitness program to crash,
;;;   resulting in all variants to come back as +worst-c-fitness+.
;;;
;;; @subsection Installing PAPI on Ubuntu
;;; Fitness evaluation requires the PAPI component and the Linux Perf
;;; functionality. Building the fitness evaluation program (on the fly
;;; during fitness evaluation) requires a C program to compile and link
;;; to PAPI. This also requires a .h file to compile.
;;;
;;; To install papi:
;;;
;;;      sudo apt-get install papi-tools
;;;
;;; To install perf:
;;;
;;;     sudo apt-get install linux-tools-common linux-tools-generic linux-tools-`uname -r`
;;;
;;; To get necessary include (.h) file for compiling C harness with PAPI
;;; (needed to perform fitness evaluation):
;;;
;;;      sudo apt-get install libpapi-dev
;;;
;;; Then you should be able to enter
;;;
;;; papi_avail
;;;
;;; and see a list of available PAPI events.
;;; ASM-SUPER-MUTANT requires the use of the PAPI_TOT_INS event (total number
;;; of instructions executed).
;;; After installation, the PAPI library should be found in one of these
;;; locations:
;;;     /usr/lib/x86_64-linux-gnu/libpapi.so
;;;     /usr/lib/libpapi.so.5.6.1
;;;
;;; @texi{asm-super-mutant}

(defpackage :software-evolution-library/software/asm-super-mutant
  (:nicknames :sel/software/asm-super-mutant :sel/sw/asm-super-mutant)
  (:use :common-lisp
        :alexandria
	:command-line-arguments
        :arrow-macros
        :named-readtables
        :curry-compose-reader-macros
        :iterate
        :split-sequence
        :software-evolution-library
        :software-evolution-library/utility
	:software-evolution-library/command-line
	:software-evolution-library/components/lexicase
        :software-evolution-library/software/asm
        :software-evolution-library/software/asm-heap
        :software-evolution-library/software/super-mutant)
  (:export :asm-super-mutant
           :var-table
           :*lib-papi*
           :fitness-harness
           :load-io-file
           :target-function
           :target-function-name
           :create-all-simple-cut-variants
           :create-target
           :target-info
           :evaluate-asm
           :leaf-functions
           :parse-sanity-file))
(in-package :software-evolution-library/software/asm-super-mutant)
(in-readtable :curry-compose-reader-macros)

(define-software asm-super-mutant (asm-heap super-mutant)
  ((input-spec
    :initarg :input-spec
    :accessor input-spec
    :initform (make-array 0 :fill-pointer 0 :adjustable t)
    :documentation
    "Vector of INPUT-SPECIFICATION structs, one for each test case.")
   (output-spec
    :initarg :output-spec
    :accessor output-spec
    :initform (make-array 0 :fill-pointer 0 :adjustable t)
    :documentation
    "Vector of INPUT-SPECIFICATION structs, one for each test case.")
   (var-table
    :initarg :var-table
    :accessor var-table
    :initform nil
    :documentation "Vector of var-rec (data/address records)")
   (bss-segment
    :initarg :bss-segment
    :accessor bss-segment
    :initform nil
    :documentation "Address of bss segment in original executable")
   (target-name
    :initarg :target-name
    :accessor target-name
    :initform nil
    :documentation "Name of target function")
   (target-start-index
    :initarg :target-start-index
    :accessor target-start-index
    :documentation "Integer index represents the first line of target code.")
   (target-end-index
    :initarg :target-end-index
    :accessor target-end-index
    :documentation "Integer index represents the last line of target code.")
   (target-info
    :initarg :target-info
    :accessor target-info
    :initform nil
    :documentation "Function index entry of the target function")
   (target-lines
    :initarg :target-lines
    :accessor target-lines
    :documentation "Cache the lines of the target code, as they are used often.")
   (assembler
    :initarg :assembler
    :accessor assembler
    :initform "nasm"
    :documentation "Assembler to use for assembling.")
   (io-dir
    :initarg :io-dir
    :accessor io-dir
    :initform nil
    :documentation "Directory containing I/O files, named for the functions.")
   (io-file
    :initarg :io-file
    :accessor io-file
    :initform nil
    :documentation "If this is specified, use this file (ignore io-dir).")
   (fitness-harness
    :initarg :fitness-harness
    :accessor fitness-harness
    :initform "./asm-super-mutant-fitness.c"
    :documentation "Pathname to the fitness harness file (C program source)"))
  (:documentation
   "Combine SUPER-MUTANT capabilities with ASM-HEAP framework."))

;; C 64-bit unsigned long MAXINT, is the worst possible fitness score
(defconstant +worst-c-fitness+ #xffffffffffffffff)

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
  (format stream "~16,'0X: ~T~A ~A"
	  (memory-spec-addr mem)
	  (Memory-spec-mask mem)
	  (bytes-to-string (memory-spec-bytes mem))))

(defstruct reg-contents
  name     ; name of register (string) i.e. "rax", "ymm1", etc.
  value)   ; integer value (64 bits for gen. purpose, 256 bit for SIMD)

(defmethod print-object ((reg reg-contents) stream)
  (format stream "~4A: ~A" (reg-contents-name reg)
	  (bytes-to-string (reg-contents-value reg))))

;;;
;;; This struct also is used to specify outputs.
;;;
(defstruct input-specification
  regs
  simd-regs
  mem)   ;; vector of memory-spec to indicate all memory inputs

(defmethod print-object ((spec input-specification) stream)
  (print-unreadable-object (spec stream)
    (format
     stream
     "input-specification: ~D registers, ~D SIMD registers, ~D memory addrs"
     (length (input-specification-regs spec))
     (length (input-specification-simd-regs spec))
     (length (input-specification-mem spec)))))

(defmethod initialize-instance :after ((instance asm-super-mutant)
				       &rest initargs)
  (declare (ignore initargs))
  ;; if a path was assigned to var-table
  ;; parse it and replace the value with the table
  (if (or (stringp (var-table instance)) (pathnamep (var-table instance)))
      (setf (var-table instance)
	    (parse-sanity-file (var-table instance)))))

(defmethod from-file :after ((asm asm-super-mutant) file)
  "Set function target after the file loads."
  ;; if target-name non-nil, set the target
  (declare (ignore file))
  (if (target-name asm)
      (target-function-name asm (target-name asm)))
  asm)

;;;
;;; Store name and address of data variables
;;;
(defstruct var-rec
  name     ; string, name of variable
  type     ; string, "b", "r", "d", "?"
  address) ; integer address

;;; whitespace handling
;;;
(defun is-whitespace (c)
  (member c '(#\space #\linefeed #\newline #\tab #\page)))

(defun get-next-line (input)
  (let ((line (read-line input nil 'eof)))
    (if (stringp line)
	(trim-whitespace line))))  ;; returns nil if end-of-file

(defparameter *fitness-harness* "./asm-super-mutant-fitness.c")

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

(defun new-io-spec ()
  (make-input-specification
   :regs (make-array 16 :fill-pointer 0)
   :simd-regs (make-array 16 :fill-pointer 0)
   :mem (make-array 0 :fill-pointer 0 :adjustable t)))

(defun load-io-file (super-asm filename)
  "Load the file containing input and output state information"
  (let ((input-spec (new-io-spec))
	(output-spec (new-io-spec))
	(parsing-inputs t))
    (with-open-file (input filename :direction :input)
      (do ((line (get-next-line input) (get-next-line input))
	   (pos 0 0))
	  ((null line)
	   (when (> (length (input-specification-regs output-spec)) 0)
	     (vector-push-extend output-spec (output-spec super-asm))))
	(cond ((zerop (length line))) ; do nothing, empty line
	      ((search "Input data" line)
	       (when (> (length (input-specification-regs output-spec)) 0)
	         (vector-push-extend output-spec (output-spec super-asm))
	         (setf output-spec (new-io-spec)))
	       (setf parsing-inputs t))
	      ((search "Output data" line)
	       (vector-push-extend input-spec (input-spec super-asm))
	       (setf input-spec (new-io-spec))
	       (setf parsing-inputs nil))
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
		 (if parsing-inputs input-spec output-spec))))))))
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
  (let ((label (gensym "reg_cmp_")))
    (list
     (format nil "push ~A" reg)
     (format nil "mov qword ~A, 0x~X"
	     reg
	     (be-bytes-to-qword bytes))
     (format nil "cmp qword ~A, [rsp]" reg)
     (format nil "pop ~A" reg)
     (format nil "je ~A" label)
     "mov rdi, qword [$stdout@@GLIBC_2.2.5]"
     "mov rsi, $error_reg_compare"
     (format nil "mov qword rdx, 0x~X" (be-bytes-to-qword bytes)) ; expected
     "call $fprintf wrt ..plt"
     (format nil "jmp $output_reg_comparison_failure")
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
	 (format nil "mov qword rax, 0x~X" (be-bytes-to-qword bytes))
	 (format nil "mov qword rcx, 0x~X" addr)
	 "mov qword [rcx], rax")
	(list
	 (format nil "mov qword rax, 0x~X" (be-bytes-to-qword bytes))
	 (format nil "mov qword rbx, 0x~X"
		 (be-bytes-to-qword (create-byte-mask mask)))
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
	(label (gensym "$mem_cmp_")))
    (if (equal mask #*11111111)  ;; we can ignore the mask
	(list
	 (format nil "mov qword rax, 0x~X" (be-bytes-to-qword bytes))
	 (format nil "mov qword rcx, 0x~X" addr)
	 "cmp qword [rcx], rax"
	 (format nil "je ~A" label)
         (format nil "jmp $output_comparison_failure")
         (format nil "~A:" label))
	(list
	 (format nil "mov qword rax, 0x~X" (be-bytes-to-qword bytes))
	 (format nil "mov qword rbx, 0x~X"
		 (be-bytes-to-qword (create-byte-mask mask)))
	 (format nil "mov qword rcx, 0x~X" addr)
	 "mov qword rdx, [rcx]"
	 "and rax, rbx"   ; mask off unwanted bytes of src
	 "and rdx, rbx" ; mask off unwanted bytes of dest
	 "cmp rdx, rax"
	 (format nil "je ~A" label)
         (format nil "jmp $output_comparison_failure")
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
	 (asm (make-instance 'asm-heap :super-owner asm-super)))
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
		       (comp-reg (reg-contents-name x)
				 (reg-contents-value x))))))
	 (mem-lines
	  (apply 'append
		 (iterate
	           (for x in-vector (input-specification-mem output-spec))
		   (collect (comp-mem x)))))
	 (asm (make-instance 'asm-heap :super-owner asm-super)))
    (setf (lines asm) (append reg-lines mem-lines))
    asm))

(defun target-function (asm-super start-addr end-addr)
  "Define the target function by specifying start address and end address"
  (let* ((genome (genome asm-super))
	 (start-index
	  (position start-addr genome
		    :key 'asm-line-info-address
		    :test (lambda (x y)(and y (= x y))))) ;; skip null address
	 (end-index
	  (position end-addr genome
		    :key 'asm-line-info-address
		    :start (if start-index start-index 0)
		    :test (lambda (x y)(and y (= x y))))))
    (setf (target-start-index asm-super) start-index)
    (setf (target-end-index asm-super) end-index)
    (setf (target-lines asm-super)
	  (if (and start-index end-index)
	      (subseq genome start-index (+ 1 end-index))
	      nil))))

(defun target-function-name (asm function-name)
  "Specify target function by name. The name can be a symbol or a string. If
a symbol, the SYMBOL-NAME of the symbol is used."
  (let* ((name
	  (if (stringp function-name)
	      function-name
	      (symbol-name function-name)))
	 (index-entry (find name (function-index asm)
			    :key 'function-index-entry-name
			    :test 'equalp)))
    (when index-entry
      (target-function
       asm
       (function-index-entry-start-address index-entry)
       (function-index-entry-end-address index-entry))
      (load-io-file
       asm
       (or (and (io-file asm) (pathname (io-file asm)))
	   (merge-pathnames
	    (pathname (io-dir asm))
	    (make-pathname :name function-name))))
      (setf (target-info asm) index-entry))))


(defun find-main-line (asm-super)
  (find "$main:" (genome asm-super) :key 'asm-line-info-text :test 'equal))

(defun find-main-line-position (asm-super)
  (position "$main:" (genome asm-super) :key 'asm-line-info-text :test 'equal))

;;;
;;; Look for any label in the text (string starting with $ and ending with : or
;;; white space) and add suffix text to end of label (should be something like
;;; "_variant_1"). Returns the result (does not modify passed text).
;;; Do not change labels which are used as data, i.e. referenced in non-branch
;;; instructions. For now--we will assume branch instructions are all
;;; ops which start with the letter "j". Also do not change labels used as
;;; branch targets if the name contains #\@ (signifies non-local label).
;;;
(defun add-label-suffix (text suffix)
  (multiple-value-bind (start end register-match-begin register-match-end)
      (ppcre:scan "\\$[\\w@]+" text)
    (declare (ignore register-match-begin register-match-end))
    (if (and (integerp start)
	     (integerp end)
	     (or
	      (and (char= #\j (char (string-trim '(#\space #\tab) text) 0))
		   (not (find #\@ text :start start :end end)))
	      (char= #\$ (char (string-trim '(#\space #\tab) text) 0))))
	(concatenate 'string
		     (subseq text 0 end)
		     suffix
		     (subseq text end))
	text)))

;;;
;;; Insert prolog code at the beginning of the file.
;;;
(defun add-prolog (asm num-variants index-info)
  (insert-new-lines
   asm
   (append
    (list
     "; -------------- Globals (exported) ---------------"
     "        global variant_table"
     "        global input_regs"
     "        global output_regs"
     "        global input_mem"
     "        global output_mem"
     "        global num_tests"
     "        global save_return_address"    ; save address to return to
     "        global result_return_address   ; keep track of what we found")
    (iter (for i from 0 below num-variants)
	  (collect (format nil "        global variant_~D" i)))
    (list
     ""
     "; -------------- Stack Vars ---------------")
    (mapcar 'asm-line-info-text
	    (function-index-entry-declarations index-info))
    (list
     ""
     "; -------------- Stack --------------"
     "section .note.GNU-stack noalloc noexec nowrite progbits"
     ""
     "; ----------- Code & Data ------------"
     "section .text exec nowrite  align=16"
     "      align 4"))
   0))

(defun add-externs (asm asm-super)
  (insert-new-lines
   asm
   (append
    (list
     ""
     "; -------------- Externs ---------------")
    (iter (for x in-vector (genome asm-super))
	  (if (and (eq (asm-line-info-type x) ':decl)
		   (eq (first (asm-line-info-tokens x))
                       'software-evolution-library/asm::extern))
	      (collect (asm-line-info-text x))))
    (list ""))
   (length (genome asm))))

;;;
;;; Replace a RET operation with:
;;;    	pop qword [result_return_address]
;;;	jmp qword [save_return_address]
;;;
;;; This accomplishes the same thing, but ensures that we will be returning
;;  to the correct address (in case stack is corrupted).
;;; It also caches the stack return value so the C harness can determine
;;; whether there was a problem with the stack.
;;;
;;; The passed argument is a vector of asm-line-info, and this returns
;;; a list of asm-line-info.
;;;
(defun handle-ret-ops (asm-lines)
  (let ((new-lines '()))
    (iter (for line in-vector asm-lines)
	  (if (eq (asm-line-info-opcode line) 'sel/asm::ret)
	      (progn
		(push (car (parse-asm-line
			    "        pop qword [result_return_address]"))
		      new-lines)
	        (push (car (parse-asm-line
			    "        jmp qword [save_return_address]"))
		      new-lines))
	      (push line new-lines)))
    (nreverse new-lines)))

;;; Append a variant function, defined by the name and
;;; lines of assembler code,
;;;
(defun add-variant-func (asm-variant name lines)
  (let* ((suffix (format nil "_~A" name))
	 (localized-lines
	  (mapcar
	   (lambda (line)
	     (add-label-suffix line suffix))
	   lines)))
    (insert-new-lines
     asm-variant
     (append
      (list
       (format nil "~A:" name)  ; function name
       "        pop qword [save_return_address] ; save the return address"
       "        push qword [save_return_address]")
      (cdr localized-lines)   ; skip first line, the function name
      (list "ret"   ; probably redundant, already in lines
	    "align 4"))
     (length (genome asm-variant)))))

(defun format-reg-specs (io-spec)
  (iter (for reg-spec in-vector (input-specification-regs io-spec))
	(collect
	    (format nil "    dq 0x~16,'0X  ; ~A"
		    (be-bytes-to-qword (reg-contents-value reg-spec))
		    (reg-contents-name reg-spec)))))

;;;
;;; for each memory entry, add three qwords: address, data, mask.
;;; The mask is in the format (eg.): 0xff00000000000000
;;; (this means the high byte only is used)
;;; The list is terminated with an address of 0.
;;;
(defun format-mem-specs (io-spec)
  (let ((lines
	 (iter (for spec in-vector (input-specification-mem io-spec))
	       (collect
		   (let ((addr (memory-spec-addr spec))
			 (mask (memory-spec-mask spec))
			 (bytes (memory-spec-bytes spec)))
		     (format
		      nil
		      "    dq 0x~16,'0X~%    dq 0x~16,'0X~%    dq 0x~A~%"
		      addr
		      (be-bytes-to-qword bytes)
		      (apply 'concatenate 'string
			     (map 'list
				  (lambda (x)
				    (if (= x 1) "FF" "00"))
				  mask))))))))
    (append lines (list "    dq 0"))))    ; and with zero address

(defun add-variant-table (asm num-variants)
  (insert-new-lines
   asm
   (list
    ""
    ";;;  table of function pointers, 0-terminated"
    "variant_table:")
   (length (genome asm)))
  (dotimes (i num-variants)
    (insert-new-line
     asm
     (format nil "        dq variant_~D" i)
     (length (genome asm))))
  (insert-new-line asm "        dq 0" (length (genome asm))))

(defun format-reg-info (asm-variants spec-vec label)
  (insert-new-lines asm-variants (list "" label) (length (genome asm-variants)))
  (dotimes (i (length spec-vec))
    (insert-new-lines
     asm-variants
     (format-reg-specs (aref spec-vec i))
     (length (genome asm-variants)))
    (insert-new-line asm-variants "" (length (genome asm-variants)))))

(defun format-mem-info (asm-variants spec-vec label)
  (insert-new-lines asm-variants (list "" label) (length (genome asm-variants)))
  (dotimes (i (length spec-vec))
    (insert-new-lines
     asm-variants
     (format-mem-specs (aref spec-vec i))
     (length (genome asm-variants)))
    (insert-new-line asm-variants "" (length (genome asm-variants)))))

(defun add-bss-section (asm-variants asm-super)
  ;; if bss section found, add it
  (let ((bss (extract-section asm-super ".BSS")))
    (if bss
	(insert-new-lines
	 asm-variants
	 (cons "section .seldata noexec write align=32"
	       (cdr (lines (extract-section asm-super ".BSS"))))
	 (length (genome asm-variants)))
	(insert-new-lines
	 asm-variants
	 (list "section .seldata noexec write align=32"
	"    times 16 db 0"
	"    times  8 db 0"
	"    times  8 db 0"
	"    times  8 db 0")
	 (length (genome asm-variants))))))

(defun add-return-address-vars (asm-variants)
  (insert-new-lines
   asm-variants
   (list
    "        ; save address to return back to, in case the stack is messed up"
    "        save_return_address: resb 8"
    "        ; save the address found on the stack (should be the same)"
    "        result_return_address: resb 8"
    "")
   (length (genome asm-variants))))

(defun add-io-tests (asm-super asm-variants)
  "Copy the I/O data from the asm-super into the asm-variants assembly file"
  (insert-new-lines
   asm-variants
   (list
    ""
    ";;;  number of test cases"
    "num_tests:")
   (length (genome asm-variants)))
  (insert-new-line
   asm-variants
   (format nil "        dq ~d" (length (input-spec asm-super)))
   (length (genome asm-variants)))
  (format-reg-info asm-variants (input-spec asm-super) "input_regs:")
  (format-reg-info asm-variants (output-spec asm-super) "output_regs:")
  (format-mem-info asm-variants (input-spec asm-super) "input_mem:")
  (format-mem-info asm-variants (output-spec asm-super) "output_mem:"))

;;;
;;; considers the variants have the same super-owner if its super-owner's
;;; genome is equalp to the target asm-super-mutant
;;;
(defun generate-file (asm-super output-path number-of-variants)
  (let ((asm-variants (make-instance 'asm-heap :super-owner asm-super)))
    (setf (lines asm-variants) (list))  ;; empty heap
    (add-prolog asm-variants number-of-variants (target-info asm-super))
    ;(add-externs asm-variants asm-super) ;this creates linker problem currently
    (let ((count 0))
      (dolist (v (mutants asm-super))
	(assert (equalp (genome (super-owner v)) (genome asm-super)) (v)
                "Variant is not owned by this asm-super-mutant")
        (add-variant-func
	 asm-variants
	 (format nil "variant_~D" count)
	 (mapcar 'asm-line-info-text (handle-ret-ops (genome v))))
	(incf count)))
    (add-variant-table asm-variants number-of-variants)
    (add-io-tests asm-super asm-variants)
    (add-bss-section asm-variants asm-super)
    (add-return-address-vars asm-variants)
    (setf (super-soft asm-super) asm-variants)  ;; cache the asm-heap
    (with-open-file (os output-path :direction :output :if-exists :supersede)
      (dolist (line (lines asm-variants))
	(format os "~A~%" line)))
    ;; (format t "File ~A successfully created.~%" output-path)
    output-path))

(defun create-target (asm-super)
  "Returns an ASM-HEAP software object which contains only the target lines."
  (let ((asm (make-instance 'asm-heap :super-owner asm-super)))
    (setf (lines asm)(map 'list 'asm-line-info-text (target-lines asm-super)))
    asm))

(defun create-variant-file (input-source io-file output-path
			    start-addr end-addr)
  (let ((asm-super
	 (from-file (make-instance 'asm-super-mutant) input-source)))
    (load-io-file asm-super io-file)
    (target-function asm-super start-addr end-addr)
    (generate-file asm-super output-path 2)))

(defvar *lib-papi*
  (or (probe-file "/usr/lib/x86_64-linux-gnu/libpapi.so")
      (probe-file "/usr/lib/libpapi.so.5.6.1"))
  "Path to papi library.  See http://icl.cs.utk.edu/papi/.")

(defmethod phenome ((asm asm-super-mutant)
		    &key (bin (temp-file-name "out"))
		      (src (temp-file-name "asm")))
  "Create ASM file, assemble it, and link to create binary BIN."
  (let ((src (generate-file asm src (length (mutants asm)))))
    (with-temp-file (obj "o")
      ;; Assemble.
      (multiple-value-bind (stdout stderr errno)
          (shell "~a -f elf64 -o ~a ~a" (assembler asm) obj src)
	(declare (ignorable stdout stderr))
        (restart-case
            (unless (zerop errno)
              (error (make-condition 'phenome :text stderr :obj asm :loc src)))
          (retry-project-build ()
            :report "Retry `phenome' assemble on OBJ."
            (phenome obj :bin bin))
          (return-nil-for-bin ()
            :report "Allow failure returning NIL for bin."
            (setf bin nil)))
        (when (zerop errno)
          ;; Link.
	  (multiple-value-bind (stdout stderr errno)
	    (shell
	     "clang -no-pie -O0 -fnon-call-exceptions -g ~a -lrt -o ~a ~a ~a ~a"
	     (if (bss-segment asm)
		 (format nil "-Wl,--section-start=.seldata=0x~x"
			 (bss-segment asm))
		 "")
	     bin
	     (fitness-harness asm)
	     obj
	     *lib-papi*)
            (restart-case
                (unless (zerop errno)
                  (error (make-condition 'phenome :text stderr
					 :obj asm :loc obj)))
              (retry-project-build ()
                :report "Retry `phenome' link on OBJ."
                (phenome obj :bin bin))
              (return-nil-for-bin ()
                :report "Allow failure returning NIL for bin."
                (setf bin nil)))
	    (setf (phenome-results asm)
		  (list bin errno stderr stdout src))
	    (values bin errno stderr stdout src)))))))

(defmethod evaluate ((test symbol)(asm-super asm-super-mutant)
		     &rest extra-keys
		     &key
		       &allow-other-keys)
  "Create phenome (binary executable) and call it to generate fitness results.
The variants need to already be created (stored in mutants slot) and the io-file
needs to have been loaded, along with the var-table by PARSE-SANITY-FILE."
  (declare (ignore extra-keys test))  ; currently ignore the test argument

  (let* ((*fitness-predicate* #'<)    ; lower fitness number is better
	 (*worst-fitness* (worst-numeric-fitness)))
    (with-temp-file (bin)
      (multiple-value-bind (bin-path phenome-errno stderr stdout src)

	  ;;(handler-case
	      (phenome asm-super :bin bin)
	  ;;  (phenome () (values nil 1 "" "" nil)))

	(declare (ignorable phenome-errno stderr stdout src))
	(let ((test-results nil))
	  (if (zerop phenome-errno)
	      ;; run the fitness program
	      (multiple-value-bind (stdout stderr errno)
		  (shell "~a" bin-path)
		(declare (ignorable stderr errno))
		(if (/= errno 0)
		    (setf phenome-errno errno)
		    (setf test-results
			  (read-from-string
			   (concatenate 'string "#(" stdout ")"))))))
	  (if (null test-results)
	      ;; create array of *worst-fitness*
	      (setf test-results
		    (make-array (* (length (mutants asm-super))
				   (length (input-spec asm-super)))
				:initial-element *worst-fitness*)))
	  (let* ((num-tests (length (input-spec asm-super)))
		 (num-variants (/ (length test-results) num-tests))
		 (results '()))
	    ;; any that came back +worst-c-fitness+ replace with *worst-fitness*
	    (dotimes (i (length test-results))
	      (let ((test-result (aref test-results i)))
	        (assert (> test-result 0) (test-result)
			"The fitness cannot be zero")
		(if (= (elt test-results i) +worst-c-fitness+)
		    (setf (elt test-results i) *worst-fitness*))))
	    ;; set fitness vector for each mutant
	    (dotimes (i num-variants)
	      (let ((variant-results
		     (subseq test-results
			     (* i num-tests) (* (+ i 1) num-tests))))
		(setf (fitness (elt (mutants asm-super) i))
		      variant-results)
		(push variant-results results)))
	    (setf test-results (nreverse results)))
	  (setf (fitness asm-super) test-results))))))

(defun add-simple-cut-variant (asm-super i)
  (let* ((orig (create-target asm-super))
         (variant (apply-mutation orig
				  (make-instance 'sel/sw/simple::simple-cut
						 :object orig :targets i))))
    (push variant (mutants asm-super))))

;;;
;;; Returns a population of variants, to be added to the asm-super mutants list.
;;; It will not do simple-cut operations on label declaration lines (which will
;;; simply break compilation). It will also skip the first instruction which is
;;; typically "push rbp", as this will cause the return address to be lost and
;;; definitely break.
;;;
(defun create-all-simple-cut-variants (asm-super)
  (let* ((orig (create-target asm-super))
	 (lines (genome orig))
	 (variants '())
	 (index 0))
    (iter (for line in-vector lines)
	  (unless
	      (or ;(= index 14) ;; causes infinite loop
	       (eq (asm-line-info-type line) ':label-decl))
	    (push
	     (apply-mutation
	      (copy orig)
	      (make-instance 'sel/sw/simple::simple-cut
			     :object orig :targets index))
	     variants)
	    ;; (format t "Cutting index ~D, line: ~A~%" index
	    ;;    (asm-line-info-text line))
	    )
	  (incf index))
    (nreverse variants)))

(defun section-header-p (asm-info)
  "If the passed asm-line-info is a section header, returns the section name.
Else returns NIL."
  (if (and (eq (asm-line-info-type asm-info) ':decl)
	   (eq (first (asm-line-info-tokens asm-info)) 'sel/asm::section))
      (symbol-name (second (asm-line-info-tokens asm-info)))))

(defun find-named-section (asm-super name)
  "Returns the starting line (integer) of the named section or
NIL if not found."
  (position-if
   (lambda (x)
     (equalp (section-header-p x) name))
   (genome asm-super)))

(defun extract-section (asm-super section-name)
  "Given the name (string) of a section, extract all the lines from
the named section into a new asm-heap, and return that. If not found,
returns NIL."
  (let ((named-section-pos (find-named-section asm-super section-name)))
    (if named-section-pos
	(let ((end (position-if 'section-header-p (genome asm-super)
				:start (+ named-section-pos 1))))
	  (if (null end)
	      (setf end (- (length (genome asm-super)) 1)))
	  (let ((section (make-instance 'asm-heap :super-owner asm-super)))
	    (setf (lines section)
		  (map 'list 'asm-line-info-text
		       (subseq (genome asm-super) named-section-pos end)))
	    section)))))

(defun leaf-functions (asm-super)
  (map 'list
       (lambda (x)
	 (string-downcase (function-index-entry-name x)))
       (remove-if-not (lambda (x) (function-index-entry-is-leaf x))
		      (function-index asm-super))))

(defun parse-sanity-file (filename)
  "Parses the 'sanity' file which is output by the GTX disassembler. It
contains all the data variables and addresses (some of which are not
included in the disassembly file). Returns a vector of var-rec."
  (with-open-file (is filename)
    (do* ((recs '())
	  (line (read-line is nil nil) (read-line is nil nil)))
	 ((null line)(make-array (length recs)
				 :initial-contents (nreverse recs)))
      (let* ((tokens (split-sequence #\space line))
	     (name (first tokens))
	     (type (second tokens))
	     (address (parse-integer (third tokens) :radix 16)))
	(push (make-var-rec :name name :type type :address address) recs)))))

(defun bss-segment-address (asm-super)
  (or (bss-segment asm-super)
      (let ((first-bss-var
	     (find "b" (var-table asm-super) :test 'equal :key 'var-rec-type)))
	(var-rec-address first-bss-var))))
