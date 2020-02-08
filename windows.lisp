#|
 This file is a part of cl-gamepad
 (c) 2020 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.gamepad.impl)

(defvar *devices-need-refreshing* T)
(defvar *device-table* (make-hash-table :test 'eql))
(defvar *directinput*)
(defvar *device-notifier*)
(defvar *poll-event*)
(defconstant EVENT-BUFFER-COUNT 32)

(defstruct (device-notifier
            (:constructor make-device-notifier (class window notification))
            (:copier NIL)
            (:predicate NIL))
  (notification)
  (window)
  (class))

(cffi:defcallback device-change :pointer ((window :pointer) (message :uint) (wparam wparam) (lparam :pointer))
  (case message
    (:device-change
     (when (and (or (eql :device-arrival wparam)
                    (eql :device-remove-complete wparam))
                (eql :device-interface (broadcast-device-interface-device-type lparam)))
       (setf *devices-need-refreshing* T))))
  (default-window-handler window message wparam lparam))

(cffi:defcallback enum-devices enumerate-flag ((device :pointer) (user :pointer))
  (print (cffi:mem-ref device '(:struct device-instance)))
  (let* ((idx (enum-user-data-device-count user))
         (source (cffi:foreign-slot-pointer device '(:struct device-instance) 'guid))
         (target (cffi:mem-aptr (enum-user-data-device-array user) '(:struct guid) idx)))
    ;; GUID is 128 bits, copy in two uint64 chunks.
    (setf (cffi:mem-aref target :uint64 0) (cffi:mem-aref source :uint64 0))
    (setf (cffi:mem-aref target :uint64 1) (cffi:mem-aref source :uint64 1))
    (setf (enum-user-data-device-count user) (1+ idx))
    (if (< idx 255)
        :continue
        :stop)))

(cffi:defcallback enum-objects enumerate-flag ((object :pointer) (device :pointer))
  (device-unacquire device)
  (cffi:with-foreign-object (range '(:struct property-range))
    (setf (property-range-size range) (cffi:foreign-type-size '(:struct property-range)))
    (setf (property-range-header-size range) (cffi:foreign-type-size '(:struct property-header)))
    (setf (property-range-how range) :by-id)
    (setf (property-range-type range) (device-object-instance-type object))
    ;; One byte of range
    (setf (property-range-min range) -128)
    (setf (property-range-max range) +127)
    (check-return
     (device-set-property device DIPROP-RANGE range)))
  (cffi:with-foreign-object (dword '(:struct property-dword))
    (setf (property-dword-size dword) (cffi:foreign-type-size '(:struct property-dword)))
    (setf (property-dword-header-size dword) (cffi:foreign-type-size '(:struct property-header)))
    (setf (property-dword-how dword) :by-id)
    (setf (property-dword-type dword) (device-object-instance-type object))
    ;; No dead zone, handled in user code
    (setf (property-dword-data dword) 0)
    (check-return
     (device-set-property device DIPROP-DEADZONE dword)))
  :continue)

(defclass device (gamepad::device)
  ((dev :initarg :dev :reader dev)
   (xinput :initarg :xinput :initform NIL :reader xinput)
   (poll-device :initarg :poll-device :initform NIL :reader poll-device-p)))

(defun close-device (device)
  (device-unacquire (dev device))
  (com-release (dev device))
  (slot-makunbound device 'dev))

(defun make-device-from-dev (dev)
  (check-return
   (device-set-cooperative-level dev (get-module-handle (cffi:null-pointer)) '(:background :exclusive)))
  (check-return
   (device-set-data-format dev data-format-joystick))
  (check-return
   (device-enum-objects dev (cffi:callback enum-objects) dev :axis))
  (check-return
   (device-acquire dev))
  (let ((poll-device (eq :polled-device
                         (check-return
                          (device-set-event-notification dev *poll-event*) :ok :polled-device))))
    (unless poll-device
      ;; Allow receiving buffered events
      (cffi:with-foreign-object (dword '(:struct property-dword))
        (setf (property-dword-size dword) (cffi:foreign-type-size '(:struct property-dword)))
        (setf (property-dword-header-size dword) (cffi:foreign-type-size '(:struct property-header)))
        (setf (property-dword-how dword) :device)
        (setf (property-dword-type dword) 0)
        (setf (property-dword-data dword) EVENT-BUFFER-COUNT)
        (check-return
         (device-set-property dev DIPROP-BUFFERSIZE dword))))
    (cffi:with-foreign-object (instance '(:struct device-instance))
      (check-return
       (device-get-device-info dev instance))
      (let ((guid (guid-integer (device-instance-product instance))))
        ;; FIXME: try to compare the GUID to whatever linux reports and dissect it.
        (make-instance 'device
                       :dev dev
                       :name (wstring->string (cffi:foreign-slot-pointer instance '(:struct device-instance) 'instance-name))
                       :vendor guid
                       :product guid
                       :version guid
                       :driver-version guid
                       :poll-device poll-device)))))

(defun ensure-device (guid)
  (or (gethash (guid-integer guid) *device-table*)
      (cffi:with-foreign-object (dev :pointer)
        (check-return
         (directinput-create-device *directinput* guid dev (cffi:null-pointer)))
        (setf (gethash (guid-integer guid) *device-table*)
              (make-device-from-dev (cffi:mem-ref dev :pointer))))))

(defun list-devices ()
  (loop for device being the hash-values of *device-table*
        collect device))

(defun refresh-devices ()
  (let ((to-delete (list-devices)))
    (cffi:with-foreign-objects ((devices '(:struct guid) 256)
                                (enum-data '(:struct enum-user-data)))
      (setf (enum-user-data-directinput enum-data) *directinput*)
      (setf (enum-user-data-device-array enum-data) devices)
      (setf (enum-user-data-device-count enum-data) 0)
      (check-return
       (directinput-enum-devices *directinput* :game-controller (cffi:callback enum-devices) enum-data :attached-only))
      (loop for i from 0 below (enum-user-data-device-count enum-data)
            for device = (ensure-device (cffi:mem-aptr devices '(:struct guid) i))
            do (setf to-delete (delete device to-delete)))
      (mapc #'close-device to-delete)
      (setf *devices-need-refreshing* NIL)
      (list-devices))))

(defun init ()
  (unless (boundp '*directinput*)
    (cffi:use-foreign-library ole32)
    (cffi:use-foreign-library xinput)
    (cffi:use-foreign-library dinput)
    (check-return
     (co-initialize (cffi:null-pointer) :multi-threaded))
    (setf *directinput* (init-dinput))
    (setf *device-notifier* (init-device-notifications))
    (setf *poll-event* (create-event (cffi:null-pointer) NIL NIL (string->wstring "ClGamepadPollEvent")))
    (refresh-devices)))

(defun shutdown ()
  (when (boundp '*directinput*)
    (mapc #'close-device (list-devices))
    (com-release *directinput*)
    (makunbound '*directinput*))
  (when (boundp '*device-notifier*)
    (unregister-device-notification (device-notifier-notification *device-notifier*))
    (destroy-window (device-notifier-window *device-notifier*))
    (unregister-class (device-notifier-class *device-notifier*) (get-module-handle (cffi:null-pointer)))
    (makunbound '*directinput*)
    (co-uninitialize))
  (when (boundp '*poll-event*)
    (close-handle *poll-event*)
    (makunbound '*poll-event*)))

(defun init-dinput ()
  (cffi:with-foreign-object (directinput :pointer)
    (check-return
     (create-direct-input (get-module-handle (cffi:null-pointer)) DINPUT-VERSION IID-IDIRECTINPUT8
                          directinput (cffi:null-pointer)))
    (cffi:mem-ref directinput :pointer)))

(defun init-device-notifications ()
  (cffi:with-foreign-objects ((window '(:struct window-class))
                              (broadcast '(:struct broadcast-device-interface)))
    (setf (window-class-size window) (cffi:foreign-type-size '(:struct window-class)))
    (setf (window-class-instance window) (get-module-handle (cffi:null-pointer)))
    (setf (window-class-class-name window) (string->wstring "ClGamepadMessages"))
    (setf (window-class-procedure window) (cffi:callback device-change))   
    (setf (broadcast-device-interface-size broadcast) (cffi:foreign-type-size '(:struct broadcast-device-interface)))
    (setf (broadcast-device-interface-device-type broadcast) :device-interface)
    (setf (broadcast-device-interface-guid broadcast) GUID-DEVINTERFACE-HID)
    
    (let ((class (cffi:make-pointer (register-class window))))
      (when (cffi:null-pointer-p class)
        (error "Failed to register window class."))
      (let ((window (create-window 0 (window-class-class-name window) (cffi:null-pointer)
                                   0 0 0 0 0 HWND-MESSAGE (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer))))
        (when (cffi:null-pointer-p window)
          (unregister-class class (get-module-handle (cffi:null-pointer)))
          (error "Failed to create window."))
        (let ((notify (register-device-notification window broadcast 0)))
          (when (cffi:null-pointer-p notify)
            (destroy-window window)
            (unregister-class class (get-module-handle (cffi:null-pointer)))
            (error "Failed to register device notification."))
          (make-device-notifier class window notify))))))

(defun process-window-events (notifier)
  (cffi:with-foreign-object (message '(:struct message))
    (loop with window = (device-notifier-window notifier)
          while (peek-message message window 0 0 0)
          do (when (get-message message window 0 0)
               (translate-message message)
               (dispatch-message message)))))

(defun poll-devices (&key timeout)
  (let ((ms (etypecase timeout
              ((eql T) 1000)
              ((eql NIL) 0)
              ((integer 0) (floor (* 1000 timeout))))))
    (tagbody wait
       (when (and (= 258 (wait-for-single-object (device-notifier-window *device-notifier*) ms T))
                  (eql T timeout))
         (go wait))
       (when *devices-need-refreshing*
         (refresh-devices)))))

(defun poll-events (device function &key timeout)
  (let ((dev (dev device))
        (ms (etypecase timeout
              ((eql T) 1000)
              ((eql NIL) 0)
              ((integer 0) (floor (* 1000 timeout))))))
    (cffi:with-foreign-objects ((state '(:struct joystate) EVENT-BUFFER-COUNT)
                                (count 'dword))
      (setf (cffi:mem-ref count 'dword) EVENT-BUFFER-COUNT)
      (cond ((poll-device-p device)
             (check-return (device-poll dev))
             (device-get-device-state dev (cffi:foreign-type-size '(:struct joystate)) state)
             (process-delta-state state device function))
            (T
             (loop while (and (= 258 (wait-for-single-object *poll-event* ms T))
                              (eql T timeout)))
             (check-return (device-get-device-data dev (cffi:foreign-type-size '(:struct joystate)) state count 0))
             (loop for i from 0 below (cffi:mem-ref count 'dword)
                   do (process-delta-state (cffi:mem-aptr state '(:struct joystate) i) device function)))))))

(defun process-delta-state (state device function)
  NIL)