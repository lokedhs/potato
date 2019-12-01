(in-package :potato.slashcommand)

(declaim #.potato.common::*compile-decl*)

(defun validate-command-name (cmd)
  (unless (stringp cmd)
    (potato.core:raise-web-parameter-error "Command must be a string: ~s" cmd))
  (unless (cl-ppcre:scan "^[a-zA-Z0-9]+$" cmd)
    (potato.core:raise-web-parameter-error "Illegal command format: ~s" cmd))
  (string-downcase cmd))

(defun send-slashcommand (channel user sid cmd args reply-p)
  (check-type cmd string)
  (check-type args string)
  (let ((channel (potato.core:ensure-channel channel)))
    (with-pooled-rabbitmq-connection (conn)
      (cl-rabbit:basic-publish conn 1
                               :exchange *slashcommand-request-exchange-name*
                               :routing-key (format nil "~a.~a.~a.~a"
                                                    (potato.core:channel/domain channel)
                                                    (potato.core:channel/id channel)
                                                    (encode-name-for-routing-key (potato.core:ensure-user-id user))
                                                    cmd)
                               :body (lisp-to-binary (list cmd args reply-p))
                               :properties `((:headers . (("channel" . ,(potato.core:channel/id channel))
                                                          ("domain" . ,(potato.core:channel/domain channel))
                                                          ("user" . ,(potato.core:ensure-user-id user))
                                                          ("cmd" . ,cmd)
                                                          ,@(if sid (list (cons "session" sid))))))))))

(defun process-incoming-slashcommand (data)
  (json-bind ((cid "channel")
              (command "command")
              (args "arg")
              (sid "session_id" :required nil)
              (reply-p "reply" :required nil :type :boolean))
      data
    (let ((channel (potato.core:load-channel-with-check cid)))
      (unless (stringp args)
        (potato.core:raise-web-parameter-error "arg parameter must be a string"))
      (send-slashcommand channel (potato.core:current-user) sid command args reply-p)
      (st-json:jso "result" "ok"))))

(potato.core:define-json-handler-fn-login (slashcommand-screen "/command" data nil ())
  (potato.core:with-authenticated-user ()
    (process-incoming-slashcommand data)))

(defun poll-for-commands (commands callback-fn)
  (with-rabbitmq-connected (conn)
    (let ((queue (cl-rabbit:queue-declare conn 1 :auto-delete t)))
      (dolist (command commands)
        (cl-rabbit:queue-bind conn 1 :queue queue
                                     :exchange *slashcommand-request-exchange-name*
                                     :routing-key (format nil "*.*.*.~a" command)))
      (cl-rabbit:basic-consume conn 1 queue :no-ack t)
      (loop
        for msg = (cl-rabbit:consume-message conn)
        do (funcall callback-fn msg)))))

(defun slashcommand-process-unrouted-loop ()
  "Main loop that reads messages from a queue that accepts all
unrouted messages. The messages are then forwarded to the session that
initially sent the message. The client can then show an error message
to the user."
  (with-rabbitmq-connected (conn)
    (cl-rabbit:basic-consume conn 1 *slashcommand-unrouted-command-queue* :no-ack t)
    (loop
      for msg = (cl-rabbit:consume-message conn)
      for message = (cl-rabbit:envelope/message msg)
      for props = (cl-rabbit:message/properties message)
      for headers = (getfield :headers props :accept-missing t)
      ;; Unrouted messages should be sent as an error message back to
      ;; the session that issues the command.
      do (let ((cid (cdr (assoc "channel" headers :test #'equal)))
               (uid (cdr (assoc "user" headers :test #'equal)))
               (sid (cdr (assoc "session" headers :test #'equal)))
               (cmd (cdr (assoc "cmd" headers :test #'equal))))
           (if (not (and cid uid sid cmd))
               (log:warn "Unrouted message without channel, user or session set: ~s, headers: ~s" msg headers)
               ;; ELSE: All headers set, forward the message to the client
               (cl-rabbit:basic-publish conn 1
                                        :exchange *session-notifications-exchange-name*
                                        :routing-key (format nil "~a.~a.~a"
                                                             (encode-name-for-routing-key uid)
                                                             (encode-name-for-routing-key sid)
                                                             (encode-name-for-routing-key cid))
                                        :body (lisp-to-binary (list potato.rabbitmq-notifications:*session-notification-unknown-slashcommand*
                                                                    cmd
                                                                    cid))))))))

(defmacro command-processor-loop ((args-sym &optional uid-sym sid-sym channel-sym domain-sym reply-sym) &body all-defs)
  (check-type args-sym symbol)
  (check-type uid-sym (or null symbol))
  (check-type sid-sym (or null symbol))
  (check-type channel-sym (or null symbol))
  (check-type domain-sym (or null symbol))
  (let ((msg-sym (gensym "MESSAGE-"))
        (cmd-sym (gensym "CMD-"))
        (args-int-sym (gensym "ARGS-"))
        (reply-int-sym (gensym "REPLY-"))
        (body-sym (gensym "BODY-"))
        (headers-sym (gensym "HEADERS-")))
    `(poll-for-commands
      ',(mapcar #'car all-defs)
      (lambda (,msg-sym)
        (let ((,body-sym (cl-rabbit:envelope/message ,msg-sym)))
          (destructuring-bind (,cmd-sym ,args-int-sym ,reply-int-sym)
              (binary-to-lisp (cl-rabbit:message/body ,body-sym))
            (declare (ignorable ,reply-int-sym))
            (let ((,headers-sym (cdr (assoc :headers (cl-rabbit:message/properties ,body-sym)))))
              (declare (ignorable ,headers-sym))
              (string-case:string-case (,cmd-sym)
                ,@(loop
                    for definition in all-defs
                    collect (destructuring-bind (cmd-def &rest body-def)
                                definition
                              (check-type cmd-def string)
                              (check-type body-def list)
                              `(,cmd-def (let ((,args-sym ,args-int-sym)
                                               ,@(if uid-sym
                                                     (list `(,uid-sym (cdr (assoc "user" ,headers-sym :test #'equal)))))
                                               ,@(if sid-sym
                                                     (list `(,sid-sym (cdr (assoc "session" ,headers-sym :test #'equal)))))
                                               ,@(if channel-sym
                                                     (list `(,channel-sym (cdr (assoc "channel" ,headers-sym :test #'equal)))))
                                               ,@(if domain-sym
                                                     (list `(,domain-sym (cdr (assoc "domain" ,headers-sym :test #'equal)))))
                                               ,@(if reply-sym
                                                     (list `(,reply-sym ,reply-int-sym))))
                                           (declare (ignorable ,args-sym
                                                               ,@(if uid-sym (list uid-sym))
                                                               ,@(if sid-sym (list sid-sym))
                                                               ,@(if channel-sym (list channel-sym))
                                                               ,@(if domain-sym (list domain-sym))))
                                           ,@body-def))))))))))))

;;;
;;;  Default slashcommand processor
;;;

(defun process-foo-command (args uid cid domain-id)
  (log:info "Foo command from user=~s, channel=~d, domain=~s: ~s" uid cid domain-id args))

(defun process-option-command (uid sid cid)
  (with-pooled-rabbitmq-connection (conn)
    (cl-rabbit:basic-publish conn 1
                             :exchange *session-notifications-exchange-name*
                             :routing-key (format nil "~a.~a.~a"
                                                  (encode-name-for-routing-key uid)
                                                  (encode-name-for-routing-key sid)
                                                  (encode-name-for-routing-key cid))
                             :body (lisp-to-binary
                                    (list potato.rabbitmq-notifications:*session-notification-option*
                                          "zz" cid "foo"
                                          '(("bar0" "x" :image-url "https://38.media.tumblr.com/avatar_497c78dc767d_128.png" :button-text "select-x")
                                            ("bar1" "y2" :image-url "http://www.digyourowngrave.com/content/worlds_fluffiest_kitten.jpg" :button-text "select-y2")
                                            ("bar2" "y3" :image-url "https://media.giphy.com/media/26FPvntWVkwaRWgXS/giphy.gif")))))))

(defun slashcommand-default-loop ()
  (command-processor-loop (args uid sid cid domain-id)
    ("foo" (process-foo-command args uid cid domain-id))
    ("option" (process-option-command uid sid cid))))

(potato.common.application:define-component slashcommand-default
  (:dependencies potato.common::rabbitmq)
  (:start
   (start-monitored-thread #'slashcommand-process-unrouted-loop "Slashcommand process unrouted")
   (start-monitored-thread #'slashcommand-default-loop "Slashcommand default")))
