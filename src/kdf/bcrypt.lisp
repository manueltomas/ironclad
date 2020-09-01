;;;; -*- mode: lisp; indent-tabs-mode: nil -*-
;;;; bcrypt.lisp -- implementation of the bcrypt password hashing function

(in-package :crypto)


(defconst +bcrypt-initial-hash+
  (ascii-string-to-byte-array "OrpheanBeholderScryDoubt"))
(defconst +bcrypt-pbkdf-initial-hash+
  (ascii-string-to-byte-array "OxychromaticBlowfishSwatDynamite"))

(defun bcrypt-expand-key (passphrase salt p-array s-boxes)
  (declare (type (simple-array (unsigned-byte 8) (*)) passphrase salt)
           (type blowfish-p-array p-array)
           (type blowfish-s-boxes s-boxes))
  (let ((salt-length (length salt))
        (salt-index 0)
        (data (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0)))
    (declare (type fixnum salt-length salt-index)
             (type (simple-array (unsigned-byte 8) (8)) data))
    (mix-p-array passphrase p-array)
    (dotimes (i 9)
      (xor-block 8 data 0 salt salt-index data 0)
      (setf salt-index (mod (+ salt-index 8) salt-length))
      (blowfish-encrypt-block* p-array s-boxes data 0 data 0)
      (let ((index (* 2 i)))
        (setf (aref p-array index) (ub32ref/be data 0)
              (aref p-array (1+ index)) (ub32ref/be data 4))))
    (dotimes (i 4)
      (dotimes (j 128)
        (xor-block 8 data 0 salt salt-index data 0)
        (setf salt-index (mod (+ salt-index 8) salt-length))
        (blowfish-encrypt-block* p-array s-boxes data 0 data 0)
        (let ((index (+ (* 256 i) (* 2 j))))
          (setf (aref s-boxes index) (ub32ref/be data 0)
                (aref s-boxes (1+ index)) (ub32ref/be data 4)))))))

(defun bcrypt-eksblowfish (passphrase salt rounds)
  (declare (type (simple-array (unsigned-byte 8) (*)) passphrase salt))
  (let ((passphrase (concatenate '(simple-array (unsigned-byte 8) (*))
                                 passphrase (vector 0)))
        (p-array (copy-seq +p-array+))
        (s-boxes (concatenate '(simple-array (unsigned-byte 32) (1024))
                              +s-box-0+ +s-box-1+ +s-box-2+ +s-box-3+)))
    (declare (type (simple-array (unsigned-byte 8) (*)) passphrase)
             (type blowfish-p-array p-array)
             (type blowfish-s-boxes s-boxes))
    (bcrypt-expand-key passphrase salt p-array s-boxes)
    (dotimes (i rounds)
      (initialize-blowfish-vectors passphrase p-array s-boxes)
      (initialize-blowfish-vectors salt p-array s-boxes))
    (values p-array s-boxes)))

(defmethod derive-key ((kdf bcrypt) passphrase salt iteration-count key-length)
  (declare (type (simple-array (unsigned-byte 8) (*)) passphrase salt))
  (unless (<= (length passphrase) 72)
    (error 'ironclad-error
           :format-control "PASSPHRASE must be at most 72 bytes long."))
  (unless (= (length salt) 16)
    (error 'ironclad-error
           :format-control "SALT must be 16 bytes long."))
  (unless (and (zerop (logand iteration-count (1- iteration-count)))
               (<= (expt 2 4) iteration-count (expt 2 31)))
    (error 'ironclad-error
           :format-control "ITERATION-COUNT must be a power of 2 between 2^4 and 2^31."))
  (unless (= key-length 24)
    (error 'ironclad-error
           :format-control "KEY-LENGTH must be 24."))
  (multiple-value-bind (p-array s-boxes)
      (bcrypt-eksblowfish passphrase salt iteration-count)
    (declare (type blowfish-p-array p-array)
             (type blowfish-s-boxes s-boxes))
    (let ((hash (copy-seq +bcrypt-initial-hash+)))
      (declare (type (simple-array (unsigned-byte 8) (24)) hash))
      (dotimes (i 64 hash)
        (blowfish-encrypt-block* p-array s-boxes hash 0 hash 0)
        (blowfish-encrypt-block* p-array s-boxes hash 8 hash 8)
        (blowfish-encrypt-block* p-array s-boxes hash 16 hash 16)))))

(defun bcrypt-hash (passphrase salt hash)
  (declare (type (simple-array (unsigned-byte 8) (64)) passphrase salt)
           (type (simple-array (unsigned-byte 8) (32)) hash))
  (let ((p-array (copy-seq +p-array+))
        (s-boxes (concatenate '(simple-array (unsigned-byte 32) (1024))
                              +s-box-0+ +s-box-1+ +s-box-2+ +s-box-3+)))
    (declare (type blowfish-p-array p-array)
             (type blowfish-s-boxes s-boxes))
    (bcrypt-expand-key passphrase salt p-array s-boxes)
    (dotimes (i 64)
      (initialize-blowfish-vectors salt p-array s-boxes)
      (initialize-blowfish-vectors passphrase p-array s-boxes))
    (replace hash +bcrypt-pbkdf-initial-hash+)
    (dotimes (i 64)
      (blowfish-encrypt-block* p-array s-boxes hash 0 hash 0)
      (blowfish-encrypt-block* p-array s-boxes hash 8 hash 8)
      (blowfish-encrypt-block* p-array s-boxes hash 16 hash 16)
      (blowfish-encrypt-block* p-array s-boxes hash 24 hash 24))
    (dotimes (i 8)
      (let ((index (* 4 i)))
        (declare (type (mod 32) index))
        (setf (ub32ref/le hash index) (ub32ref/be hash index))))
    hash))

(defmethod derive-key ((kdf bcrypt-pbkdf) passphrase salt iteration-count key-length)
  (declare (type (simple-array (unsigned-byte 8) (*)) passphrase salt)
           (type fixnum key-length))
  (unless (plusp iteration-count)
    (error 'ironclad-error
           :format-control "ITERATION-COUNT must be a least 1."))
  (unless (<= 1 key-length 1024)
    (error 'ironclad-error
           :format-control "KEY-LENGTH must be between 1 and 1024."))
  (let* ((key (make-array key-length :element-type '(unsigned-byte 8)))
         (salt-length (length salt))
         (salt+count (concatenate '(simple-array (unsigned-byte 8) (*))
                                  salt (vector 0 0 0 0)))
         (sha2pass (make-array 64 :element-type '(unsigned-byte 8)))
         (sha2salt (make-array 64 :element-type '(unsigned-byte 8)))
         (data (make-array 32 :element-type '(unsigned-byte 8)))
         (tmp (make-array 32 :element-type '(unsigned-byte 8)))
         (stride (ceiling key-length 32))
         (amt (ceiling key-length stride)))
    (declare (type (simple-array (unsigned-byte 8) (*)) key salt+count)
             (type (simple-array (unsigned-byte 8) (64)) sha2pass sha2salt)
             (type (simple-array (unsigned-byte 8) (32)) data tmp)
             (type fixnum stride amt))
    (digest-sequence :sha512 passphrase :digest sha2pass)
    (do ((count 1 (1+ count))
         (kl key-length))
        ((<= kl 0) key)
      (declare (type fixnum count kl))
      (setf (ub32ref/be salt+count salt-length) count)
      (digest-sequence :sha512 salt+count :digest sha2salt)
      (bcrypt-hash sha2pass sha2salt tmp)
      (replace data tmp)
      (dotimes (i (1- iteration-count))
        (digest-sequence :sha512 tmp :digest sha2salt)
        (bcrypt-hash sha2pass sha2salt tmp)
        (xor-block 32 data 0 tmp 0 data 0))
      (setf amt (min amt kl))
      (dotimes (i amt (decf kl amt))
        (let ((dest (+ (* i stride) (1- count))))
          (declare (type fixnum dest))
          (unless (< dest key-length)
            (decf kl i)
            (return))
          (setf (aref key dest) (aref data i)))))))
