(in-package :approxfun)

(defun chebyshev-points (n)
  "Construct an array of N Chebyshev points on the interval [-1,1]. "
  (unless (> n 1)
    (error "Unable to construct Chebyshev points on grid of size ~D" n))
  (let ((points (make-array n :element-type 'double-float)))
    (loop :for i :from 0 :below n
          :do (setf (aref points i) (cos (/ (* i pi) (1- n)))))
    points))

(defun sample-at-chebyshev-points (fn num-samples)
  "Sample a function FN at NUM-SAMPLES Chebyshev points."
  (let ((values (make-array num-samples :element-type 'double-float))
        (pts (chebyshev-points num-samples)))
    (loop :for i :from 0 :below num-samples
          :do (setf (aref values i)
                    (funcall fn (aref pts i))))
    values))

(defun chebyshev-coefficients (samples)
  "Get the coefficients of the Chebyshev interpolant of given SAMPLES."
  ;; we reflect to get one period [s(0), s(1), ..., s(n-1), s(n-2), ..., s(1)],
  ;; compute the FFT of this, and then truncate the results
  ;; NOTE: this could be more efficient using one of the DCT variants
  (let* ((n (length samples))
         (rlen (* 2 (1- n)))
         (reflected (make-array (list rlen)
                                :element-type '(complex double-float)))
         (results (make-array (list n)
                              :element-type '(complex double-float))))
    ;; construct reflected array
    (loop :for i :from 0 :below n
          :do (let ((val (complex (aref samples i))))
                (setf (aref reflected i) val)
                (when (< 0 i (1- n))
                  (setf (aref reflected (- rlen i)) val))))
    (let ((transformed (fft reflected)))
      ;; fft computes an unscaled transform, so we divide by n-1
      ;; note we are only keeping the first n coeffs
      (loop :for i :from 0 :below n
            :do (setf (aref results i)
                      (/ (aref transformed i) (1- n))))
      ;; we also need to scale appropriately at the boundary
      (setf (aref results 0)
            (/ (aref results 0) 2)
            (aref results (1- n))
            (/ (aref results (1- n)) 2))
      results)))


(defun samples-from-coefficients (coeffs)
  "Construct samples at Chebyshev points from an array of Chebyshev coefficients."
  ;; coeffs is length n
  ;; apply inverse fourier transform
  ;; extract real part of first n values
  (let* ((n (length coeffs))
         (extended (make-array (* 2 (1- n)) :element-type '(complex double-float))))
    ;; zero pad to length 2(n-1)
    (loop :for i :from 0 :below (* 2 (1- n))
          :do (setf (aref extended i)
                    (if (< i n) (aref coeffs i) #C(0d0 0d0))))
    (let ((inverted (fft extended :direction :backward)))
      (let ((results (make-array n :element-type 'double-float)))
        (loop :for i :from 0 :below n
              :do (setf (aref results i) (realpart (aref inverted i))))
        results))))

(defun chebyshev-interpolate (samples)
  "Given samples at the Chebyshev points, return a function computing the interpolant at an arbitrary point."
  ;; This is the so-called "Barycentric Interpolation", of Salzer
  ;; cf. https://people.maths.ox.ac.uk/trefethen/barycentric.pdf
  (let* ((n (length samples))
         (xs (chebyshev-points n)))
    (lambda (x)
      (let ((num 0d0)
            (denom 0d0))
        (loop :for i :from 0 :below (length samples)
              :for w := 1 :then (- w)
              ;; TODO: should we be checking up to FP precision below?
              ;; I think the main thing is just to rule out actual divide by zero,
              ;; but its worth considering more carefully.
              :when (= x (aref xs i))
                :do (return (aref samples i))
              :do (let ((coeff
                          (/ (if (< 0 i (1- n)) w (/ w 2))
                             (- x (aref xs i)))))
                    (incf num (* (aref samples i) coeff))
                    (incf denom coeff))
              :finally (return (/ num denom)))))))


(defun coefficient-cutoff (coeffs &key (tol 1d-15))
  "Find a cutoff point for the Chebyshev coefficients COEFFS.

This returns the last index of COEFFS which is deemed significant, or NIL if the
series if no such index is found. The heuristic used is described in Aurentz and
Trefthen, 'Chopping a Chebyshev Series'.

The tolerance TOL is a relative tolerance, used to detect when the decay of
Chebyshev coefficients is deemed to be negligible."
  (let* ((n (length coeffs))
         (max-abs (loop :for i :from 0 :below n
                        :maximizing (abs (aref coeffs i))))
         (envelope (make-array n :element-type 'double-float)))
    (cond ((>= tol 1) 0)
          ((= 0d0 max-abs) 0)
          ((< n 17) nil)
          (t
           ;; Construct monotonic envelope
           (loop :with m := 0d0
                 :for i :from (1- n) :downto 0
                 :do (setf m (max m (abs (aref coeffs i)))
                           (aref envelope i) (/ m max-abs)))
           ;; scan for a plateau
           (multiple-value-bind (plateau-idx j2)
               (loop :for j1 :from 1 :below n
                     :for j2 := (round (+ (* 1.25 j1)
                                          5))
                     :unless (< j2 n)
                       :do (return-from coefficient-cutoff nil)
                     :do (let* ((e1 (aref envelope j1))
                                (e2 (aref envelope j2))
                                (r (* 3 (- 1 (/ (log e1) (log tol))))))
                           (when (or (= e1 0d0)
                                     (< r (/ e2 e1)))
                             (return (values (1- j1) j2))))
                     :finally (return-from coefficient-cutoff nil))
             ;; fix cutoff at a point where envelope + an affine function
             ;; is minimal
             (cond ((= 0d0 (aref envelope plateau-idx))
                    plateau-idx)
                   (t
                    (let ((j3 (loop :for i :from 0 :below n
                                    :until (< (aref envelope i)
                                              (expt tol (/ 7 6)))
                                    :finally (return i))))
                      (when (< j3 j2)
                        (setf j2 (1+ j3)
                              (aref envelope j2) (expt tol (/ 7 6))))
                      (loop :with min := 1d0
                            :with idx := 0
                            :for i :from 0 :to j2
                            :for cc := (+ (log (aref envelope i) 10)
                                          (/ (* i -1/3 (log tol 10))
                                             j2))
                            :when (< cc min)
                              :do (setf min cc
                                        idx i)
                            :finally (return (max (1- idx) 1)))))))))))
