;; Simple refraction example
(in-package :cepl)

;; NOTE: Ensure you have loaded cepl-image-helper & cepl-model-helper
;;       (or just load cepl-default)

;;--------------------------------------------------------------
;; setup

(defparameter *bird* nil)
(defparameter *wibble* nil)
(defparameter *camera* nil)
(defparameter *light* nil)
(defparameter *bird-tex* nil)
(defparameter *bird-tex2* nil)
(defparameter *wib-tex* nil)
(defparameter *loop-pos* 0.0)

(defclass entity ()
  ((gstream :initform nil :initarg :gstream :accessor gstream)
   (position :initform (v! 0 0 -1) :initarg :pos :accessor pos)
   (rotation :initform (v! 0 0 0) :initarg :rot :accessor rot)
   (scale :initform (v! 1 1 1) :initarg :scale :accessor scale)
   (mesh :initarg :mesh :reader mesh)))

(defclass light ()
  ((position :initform (v! 20 20 -20) :initarg :pos :accessor pos)
   (radius :initform 1.0 :initarg :radius :accessor radius)))

(defun load-model (file-path nth-mesh &optional hard-rotate)
  (let* ((imp-mesh (elt (classimp:meshes (classimp:import-into-lisp file-path))
                        nth-mesh))
         (result (model-parsers:mesh->gpu imp-mesh))
         (mesh (make-instance 'meshes:mesh
                              :primitive-type :triangles
                              :vertices (first result)
                              :index (second result)))
         (mesh~1 (if hard-rotate
                     (meshes:transform-mesh mesh :rotation hard-rotate)
                     mesh)))
    (let ((gstream (make-buffer-stream
                    (meshes:vertices mesh) :index-array (meshes:indicies mesh))))
      (make-instance 'entity :rot (v! 1.57079633 1 0) :gstream gstream
                     :pos (v! 0 -0.4 -1) :mesh mesh~1))))

(defun init ()
  (setf *light* (make-instance 'light))
  (setf *camera* (make-camera))
  (setf *wibble* (load-model (merge-pathnames "wibble.3ds" *examples-dir*)
                             0 (v! pi 0 0)))
  (setf (v:z (pos *wibble*)) -3.0)
  (setf *bird* (load-model (merge-pathnames "bird/bird.3ds" *examples-dir*) 1 (v! pi 0 0)))
  (setf *bird-tex* (devil-helper:load-image-to-texture
                    (merge-pathnames "water.jpg" *examples-dir*)))
  (setf *bird-tex2* (devil-helper:load-image-to-texture
                     (merge-pathnames "bird/char_bird_col.png" *examples-dir*)))
  (setf *wib-tex* (devil-helper:load-image-to-texture
                   (merge-pathnames "brick/col.png" *examples-dir*))))

;;--------------------------------------------------------------
;; drawing

(defun-g standard-vert ((data g-pnt) &uniform (model-to-cam :mat4)
                        (cam-to-clip :mat4))
  (values (* cam-to-clip (* model-to-cam (v! (pos data) 1.0)))
          (pos data)
          (norm data)
          (v! 0.4 0 0.4 0)
          (tex data)))

(defun-g standard-frag
    ((model-space-pos :vec3) (vertex-normal :vec3) (diffuse-color :vec4)
     (tex-coord :vec2)
     &uniform (model-space-light-pos :vec3) (light-intensity :vec4)
     (ambient-intensity :vec4) (textur :sampler-2d))
  (let* ((light-dir (normalize (- model-space-light-pos
                                  model-space-pos)))
         (cos-ang-incidence
          (clamp (dot (normalize vertex-normal) light-dir) 0.0 1.0))
         (t-col (texture textur (v! (x tex-coord) (- (y tex-coord))))))
    (+ (* t-col light-intensity cos-ang-incidence)
       (* t-col ambient-intensity))))

(defun-g refract-vert ((data g-pnt) &uniform (model-to-cam :mat4)
                       (cam-to-clip :mat4))
  (values (* cam-to-clip (* model-to-cam (v! (pos data) 1.0)))
          (tex data)))

(defun-g refract-frag ((tex-coord :vec2) &uniform (textur :sampler-2d)
                       (bird-tex :sampler-2d) (fbo-tex :sampler-2d)
                       (loop :float))
  (let* ((o (v! (mod (* loop 0.05) 1.0)
                (mod (* loop 0.05) 1.0)))
         (ot (* (s~ (texture textur (+ o tex-coord)) :xy) 0.1))
         (a (texture textur tex-coord))
         (b (+ (v! (* (x gl-frag-coord) (/ 1.0 640.0))
                   (* (y gl-frag-coord) (/ 1.0 480.0)))
               (* (s~ a :xy) 0.020)
               ot))
         (c (texture fbo-tex b))
         (r (* (texture bird-tex (* (v! 1 -1) tex-coord)) 0.1)))
    (+ r c)))

(defpipeline standard-pass () (g-> #'standard-vert #'standard-frag)
  :post #'reshape)

(defpipeline refract-pass () (g-> #'refract-vert #'refract-frag)
  :post #'reshape)

(defpipeline two-pass (&uniform model-to-cam2)
    (g-> (scene (clear scene)
                (standard-pass :light-intensity (v! 1 1 1 0)
                               :textur *wib-tex*
                               :ambient-intensity (v! 0.2 0.2 0.2 1.0)))
         (nil (refract-pass :model-to-cam model-to-cam2
                            :fbo-tex (attachment scene 0)
                            :textur *bird-tex*
                            :bird-tex *bird-tex2*
                            :loop *loop-pos*)))
  :fbos (scene :c :d))

(defun draw ()
  (gl:clear :color-buffer-bit :depth-buffer-bit)
  (let* ((world-to-cam-matrix (world->cam *camera*))
         (cam-light-vec (m4:mcol*vec4 (entity-matrix *wibble*)
                                      (v! (pos *light*) 1.0))))
    (map-g #'standard-pass (gstream *wibble*)
          :textur *wib-tex*
          :ambient-intensity (v! 0.2 0.2 0.2 1.0)
          :light-intensity (v! 1 1 1 0)
          :model-space-light-pos (v:s~ cam-light-vec :xyz)
          :model-to-cam (m4:m* world-to-cam-matrix (entity-matrix *wibble*)))
    (map-g #'two-pass (gstream *wibble*) (gstream *bird*)
          :model-to-cam (m4:m* world-to-cam-matrix (entity-matrix *wibble*))
          :model-to-cam2 (m4:m* world-to-cam-matrix (entity-matrix *bird*))
          :model-space-light-pos (v:s~ cam-light-vec :xyz)))
  (update-display))



(defun entity-matrix (entity)
  (reduce #'m4:m* (list (m4:translation (pos entity))
                        (m4:rotation-from-euler (rot entity))
                        (m4:scale (scale entity)))))

;;--------------------------------------------------------------
;; controls

(evt:def-named-event-node mouse-listener (e evt:|mouse|)
  (when (typep e 'evt:mouse-motion)
    (when (eq (evt:mouse-button-state |mouse| :left) :down)
      (let ((d (evt:delta e)))
        (cond
          ((eq (evt:key-state |keyboard| :lctrl) :down)
           (v3:incf (pos *bird*) (v! (/ (v:x d) 480.0)
                                     (/ (v:y d) -640.0)
                                     0)))
          ((eq (evt:key-state |keyboard| :lshift) :down)
           (v3:incf (pos *bird*) (v! 0 0 (/ (v:y d) 300.0))))
          (t
           (setf (rot *bird*) (v:+ (rot *bird*) (v! (/ (v:y d) -100.0)
                                                    (/ (v:x d) -100.0)
                                                    0.0)))))))))

;;--------------------------------------------------------------
;; window

(defun reshape (&optional (new-dimensions (current-viewport)))
  (setf (frame-size *camera*) new-dimensions)
  (standard-pass nil :cam-to-clip (cam->clip *camera*))
  (refract-pass nil :cam-to-clip (cam->clip *camera*)))

(def-named-event-node window-listener (e evt:|window|)
  (when (eq (evt:action e) :resized)
    (reshape (evt:data e))))

;;--------------------------------------------------------------
;; main loop

(let ((running nil))
  (defun run-loop ()
    (init)
    (setf running t)
    (loop :while running :do
       (continuable
         (step-demo)
         (update-swank))))
  (defun stop-loop () (setf running nil)))

(evt:def-named-event-node sys-listener (e evt:|sys|)
  (when (typep e 'evt:will-quit) (stop-loop)))

(defun step-demo ()
  (evt:pump-events)
  (setf *loop-pos* (+ *loop-pos* 0.04))
  (setf (pos *light*) (v! (* 10 (sin (* 0.01 *loop-pos*)))
                          10
                          (* 10 (cos (* 0.01 *loop-pos*)))))
  (draw))
