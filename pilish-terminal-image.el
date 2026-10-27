;;; pilish-terminal-image.el --- Opt-in terminal image previews -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri
;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Kitty graphics adapter for Pilish's validated image previews.
;; PNGs pass through directly; optional FFmpeg conversion handles JPEG, WebP
;; and the first GIF frame, with bounded runtime, pixels and output bytes.  Preview strings
;; reserve ordinary buffer cells; this module reconciles fully visible regions
;; with terminal placements.  It never makes terminal frames claim native Emacs
;; image support.  All graphics output is opt-in and uses inline data only.
;; Terminal placements are disposable display resources, not session state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup pilish-terminal-image nil
  "Opt-in Kitty graphics previews in Pilish terminal clients."
  :group 'pilish)

(defcustom pilish-terminal-image-converter-program "ffmpeg"
  "Optional FFmpeg executable for JPEG, WebP and first-frame GIF previews.
Set to nil to disable conversion.  PNG needs no converter.  Missing or failing
conversion leaves the original textual placeholder; no shell is invoked."
  :type '(choice (const :tag "Disable conversion" nil) string)
  :group 'pilish-terminal-image)

(defcustom pilish-terminal-image-conversion-timeout 2
  "Maximum seconds to wait for each image conversion subprocess.
Timed-out processes are terminated and their temporary source is removed."
  :type 'number
  :group 'pilish-terminal-image)

(defcustom pilish-terminal-image-max-columns 60
  "Maximum number of text columns reserved for a terminal PNG preview."
  :type 'natnum
  :group 'pilish-terminal-image)

(defcustom pilish-terminal-image-max-rows 16
  "Maximum number of text rows reserved for a terminal PNG preview."
  :type 'natnum
  :group 'pilish-terminal-image)

(defcustom pilish-terminal-image-cell-aspect-ratio 0.5
  "Approximate terminal cell width divided by its height.
Used to preserve PNG proportions without terminal pixel-size queries."
  :type 'number
  :group 'pilish-terminal-image)

(cl-defstruct (pilish-terminal-image--preview
               (:constructor pilish-terminal-image--make-preview))
  data columns rows)

(defvar pilish-terminal-image-mode nil)
(defvar pilish-terminal-image--timer nil)
(defvar pilish-terminal-image--placements nil
  "Live placements, each a plist with :frame, :id and :view.
A view contains a window, buffer position, preview, and screen rectangle.")
(defvar pilish-terminal-image--next-id 1700000000)
(defvar pilish-terminal-image--last-error nil)

(defun pilish-terminal-image--frame-p (frame)
  "Return non-nil when opted-in FRAME is a live terminal client.
Enabling the mode asserts Kitty graphics support; TERM is not proof of it."
  (and pilish-terminal-image-mode
       (frame-live-p frame)
       (not (display-graphic-p frame))
       (tty-type frame)))

(defun pilish-terminal-image--uint32 (data offset)
  "Read a big-endian unsigned integer from DATA at OFFSET."
  (+ (ash (aref data offset) 24)
     (ash (aref data (+ offset 1)) 16)
     (ash (aref data (+ offset 2)) 8)
     (aref data (+ offset 3))))

(defun pilish-terminal-image--conversion-command (type source)
  "Return a bounded FFmpeg command for image TYPE in private SOURCE.
Only raster formats JPEG, GIF and WebP are accepted.  Return nil if unavailable."
  (when-let* ((program pilish-terminal-image-converter-program)
              (executable (executable-find program))
              (input (pcase type
                       ('jpeg '("-f" "image2pipe" "-c:v" "mjpeg"))
                       ('gif '("-f" "gif"))
                       ('webp '("-f" "webp_pipe")))))
    (append (list executable "-nostdin" "-hide_banner" "-loglevel" "error"
                  "-max_alloc" "67108864" "-max_pixels" "16777216"
                  "-threads" "1" "-protocol_whitelist" "file,pipe")
            input
            (list "-i" source "-map" "0:v:0" "-an" "-sn" "-dn"
                  "-frames:v" "1" "-vf"
                  "scale=w='min(1024,iw)':h='min(1024,ih)':force_original_aspect_ratio=decrease"
                  "-c:v" "png" "-threads" "1" "-f" "image2pipe" "pipe:1"))))

(defun pilish-terminal-image--convert-to-png (raw type limit)
  "Convert validated raster RAW of TYPE to a PNG no larger than LIMIT bytes.
Use a private temporary copy, never the original tool or attachment path.
Return nil on missing support, invalid output, oversized output or timeout.
At most sixteen megapixels are decoded; the result fits 1024 by 1024 pixels."
  (when (and (memq type '(jpeg gif webp))
             (numberp pilish-terminal-image-conversion-timeout)
             (> pilish-terminal-image-conversion-timeout 0))
    (let (source process chunks (bytes 0) oversized)
      (unwind-protect
          (condition-case nil
              (progn
                (setq source (make-temp-file "pilish-image-"))
                (when-let* ((command (pilish-terminal-image--conversion-command type source)))
                  (let ((coding-system-for-write 'no-conversion))
                    (write-region raw nil source nil 'silent))
                  (let ((default-directory temporary-file-directory)
                        (deadline (+ (float-time) pilish-terminal-image-conversion-timeout)))
                    (setq process
                          (make-process
                           :name "pilish-image-conversion" :buffer nil
                           :command command :connection-type 'pipe
                           :coding 'no-conversion :noquery t :sentinel #'ignore
                           :filter (lambda (proc chunk)
                                     (cl-incf bytes (string-bytes chunk))
                                     (if (> bytes limit)
                                         (progn (setq oversized t) (delete-process proc))
                                       (push chunk chunks)))))
                    (while (and (process-live-p process) (< (float-time) deadline))
                      ;; Do not reenter a transcript render via RPC or timer callbacks.
                      (accept-process-output
                       process (min 0.05 (max 0 (- deadline (float-time)))) nil 1)))
                  (when (and (eq (process-status process) 'exit)
                             (zerop (process-exit-status process))
                             (not oversized))
                    (let ((png (apply #'concat (nreverse chunks))))
                      (when (and (>= (length png) 24)
                                 (string= (substring png 0 8)
                                          (unibyte-string 137 80 78 71 13 10 26 10))
                                 (string= (substring png 12 16) "IHDR")
                                 (<= 1 (pilish-terminal-image--uint32 png 16) 1024)
                                 (<= 1 (pilish-terminal-image--uint32 png 20) 1024))
                        png)))))
            (error nil))
        (when (and process (process-live-p process))
          (delete-process process))
        (when (and source (file-exists-p source))
          (delete-file source))))))

(defun pilish-terminal-image--preview-string (raw label window)
  "Return validated PNG RAW as a reserved terminal preview after LABEL.
WINDOW supplies the initial width.  Return nil for invalid PNG dimensions or
settings.  Byte and format validation belongs to the shared image renderer."
  (when (and (>= (length raw) 24)
             (string= (substring raw 0 8) (unibyte-string 137 80 78 71 13 10 26 10))
             (string= (substring raw 12 16) "IHDR"))
    (let* ((width (pilish-terminal-image--uint32 raw 16))
           (height (pilish-terminal-image--uint32 raw 20))
           (max-columns (min pilish-terminal-image-max-columns
                             (max 0 (1- (window-body-width window)))))
           (max-rows pilish-terminal-image-max-rows)
           (aspect pilish-terminal-image-cell-aspect-ratio))
      (when (and (> width 0) (> height 0) (> max-columns 0) (> max-rows 0)
                 (numberp aspect) (> aspect 0))
        (let* ((columns (max 1 (min max-columns
                                    (floor (/ (* max-rows width)
                                              (* height aspect))))))
               (rows (max 1 (min max-rows
                                (ceiling (/ (* height columns aspect) width)))))
               (preview (pilish-terminal-image--make-preview
                         :data (base64-encode-string raw t)
                         :columns columns :rows rows))
               (cells (mapconcat (lambda (_) (make-string columns ?\s))
                                 (number-sequence 1 rows) "\n"))
               (text (concat label "\n" cells)))
          ;; A single anchor, not a payload property on every reserved cell.
          (put-text-property (1+ (length label)) (+ 2 (length label))
                             'pilish-terminal-image preview text)
          (add-hook 'after-change-functions #'pilish-terminal-image--changed nil t)
          (add-hook 'kill-buffer-hook #'pilish-terminal-image--invalidate nil t)
          text)))))

(defun pilish-terminal-image--send (frame string)
  "Send graphics STRING to FRAME's terminal without protocol replies."
  (when (frame-live-p frame)
    (send-string-to-terminal string frame)))

(defun pilish-terminal-image--delete (placement)
  "Delete only the image identified by PLACEMENT."
  (pilish-terminal-image--send
   (plist-get placement :frame)
   (format "\e_Ga=d,d=I,i=%d,q=2\e\\" (plist-get placement :id))))

(defun pilish-terminal-image--invalidate (&rest _)
  "Remove stale terminal placements before commands or redisplay."
  (let ((placements pilish-terminal-image--placements))
    (setq pilish-terminal-image--placements nil)
    (dolist (placement placements)
      (condition-case nil
          (pilish-terminal-image--delete placement)
        (error nil)))))

(defun pilish-terminal-image--changed (&rest _)
  "Prune displaced previews after transcript edits."
  (pilish-terminal-image--prune))

(defun pilish-terminal-image--retain-views (views)
  "Keep only terminal placements still represented by VIEWS."
  (let (keep)
    (dolist (placement pilish-terminal-image--placements)
      (if (member (plist-get placement :view) views)
          (push placement keep)
        (pilish-terminal-image--delete placement)))
    (setq pilish-terminal-image--placements (nreverse keep))))

(defun pilish-terminal-image--prune (&rest _)
  "Delete displaced or hidden placements without disturbing unchanged ones.
Run after commands and layout notifications.  New placements wait until the
refresh timer so terminal graphics do not interfere with Emacs redisplay."
  (when pilish-terminal-image-mode
    (condition-case err
        (pilish-terminal-image--retain-views (pilish-terminal-image--views))
      (error
       (setq pilish-terminal-image--last-error (error-message-string err))
       (pilish-terminal-image--invalidate)))))

(defun pilish-terminal-image--geometry (window position preview)
  "Return PREVIEW's screen rectangle at POSITION in WINDOW, or nil.
Only complete, unwrapped, unobscured reserved rows qualify."
  (when-let* (((zerop (window-hscroll window)))
              (visible (pos-visible-in-window-p position window t)))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char position)
        (let* ((columns (pilish-terminal-image--preview-columns preview))
               (rows (pilish-terminal-image--preview-rows preview))
               (edges (window-inside-edges window))
               (frame (window-frame window))
               (cell-width (frame-char-width frame))
               (cell-height (frame-char-height frame))
               (row (+ (nth 1 edges) (/ (nth 1 visible) cell-height)))
               ;; The observed x coordinate includes line numbers and prefixes.
               (column (+ (nth 0 edges) (/ (nth 0 visible) cell-width)))
               (valid (= position (line-beginning-position))))
          ;; A newline whose display is hidden (for example by an outline fold)
          ;; invalidates the region even if its endpoints appear on screen.
          (dotimes (index rows)
            (let ((start (pos-visible-in-window-p (point) window t))
                  (last (and (<= (+ (point) columns) (line-end-position))
                             (pos-visible-in-window-p
                              (+ (point) (1- columns)) window t))))
              (unless (and valid start last
                           (= (nth 0 start) (nth 0 visible))
                           (= (nth 1 start)
                              (+ (nth 1 visible) (* index cell-height)))
                           (= (nth 1 last) (nth 1 start))
                           (not (invisible-p (point)))
                           (not (get-char-property (point) 'display))
                           (<= columns (window-body-width window)))
                (setq valid nil)))
            (when (< index (1- rows))
              (when (or (invisible-p (line-end-position))
                        (/= (forward-line 1) 0))
                (setq valid nil))))
          (when (and valid (>= row (nth 1 edges))
                     (<= (+ row rows) (nth 3 edges))
                     (<= (+ column columns) (nth 2 edges)))
            (list row column columns rows)))))))

(defun pilish-terminal-image--views ()
  "Collect fully visible Pilish previews on opted-in terminal frames."
  (let (views terminals)
    (dolist (frame (frame-list))
      ;; One active screen per terminal, even when Emacs has multiple tty frames.
      (when (and (pilish-terminal-image--frame-p frame)
                 (eq t (frame-visible-p frame))
                 (not (memq (frame-terminal frame) terminals)))
        (push (frame-terminal frame) terminals)
        (dolist (window (window-list frame 'no-minibuffer))
          (with-current-buffer (window-buffer window)
            (when (derived-mode-p 'pilish-transcript-mode)
              (let ((position (window-start window))
                    (end (window-end window t)))
                (while (< position end)
                  (let ((preview (get-text-property position 'pilish-terminal-image)))
                    (when (pilish-terminal-image--preview-p preview)
                      (when-let* ((geometry (pilish-terminal-image--geometry
                                            window position preview)))
                        (push (list frame window position preview geometry) views))))
                  (setq position (next-single-property-change
                                  position 'pilish-terminal-image nil end)))))))))
    (nreverse views)))

(defun pilish-terminal-image--draw (view)
  "Transmit and place VIEW, returning its resource record."
  (let* ((frame (nth 0 view))
         (preview (nth 3 view))
         (geometry (nth 4 view))
         (id (cl-incf pilish-terminal-image--next-id))
         (placement (list :frame frame :id id :view view))
         (data (pilish-terminal-image--preview-data preview))
         (offset 0)
         complete)
    ;; Send chunks below Kitty's 4096-byte payload maximum.  All data is inline;
    ;; no terminal-side file reads, shared memory, or response input are needed.
    (unwind-protect
        (progn
          (while (< offset (length data))
            (let* ((end (min (+ offset 4096) (length data)))
                   (more (if (< end (length data)) 1 0)))
              (pilish-terminal-image--send
               frame
               (concat "\e_G"
                       (if (= offset 0)
                           (format "a=t,f=100,t=d,i=%d,q=2,m=%d;" id more)
                         (format "q=2,m=%d;" more))
                       (substring data offset end) "\e\\"))
              (setq offset end)))
          (pilish-terminal-image--send
           frame
           (format "\e7\e[%d;%dH\e_Ga=p,i=%d,c=%d,r=%d,C=1,q=2\e\\\e8"
                   (1+ (nth 0 geometry)) (1+ (nth 1 geometry)) id
                   (nth 2 geometry) (nth 3 geometry)))
          (setq complete t)
          placement)
      (unless complete
        (pilish-terminal-image--delete placement)))))

(defun pilish-terminal-image--refresh ()
  "Reconcile visible preview regions with owned Kitty placements."
  (when pilish-terminal-image-mode
    (condition-case err
        (let ((views (pilish-terminal-image--views)))
          (pilish-terminal-image--retain-views views)
          (dolist (view views)
            (unless (cl-find view pilish-terminal-image--placements
                             :key (lambda (p) (plist-get p :view)) :test #'equal)
              (push (pilish-terminal-image--draw view)
                    pilish-terminal-image--placements)))
          (setq pilish-terminal-image--last-error nil))
      (error
       (setq pilish-terminal-image--last-error (error-message-string err))
       (pilish-terminal-image--invalidate)))))

;;;###autoload
(define-minor-mode pilish-terminal-image-mode
  "Display fully visible Pilish image previews using Kitty terminal graphics.
This global mode is OFF by default.  Enable it only in known Kitty-compatible
terminals, such as Ghostty.  It does not probe support or enable native Emacs
image display.  PNG works directly; JPEG, WebP and first-frame GIF need FFmpeg.
Unsupported formats retain textual placeholders.  GUI rendering is
unchanged.  Reload history after enabling to regenerate existing placeholders.
Disable the mode to remove all its terminal placements."
  :global t
  :group 'pilish-terminal-image
  (when (timerp pilish-terminal-image--timer)
    (cancel-timer pilish-terminal-image--timer))
  (setq pilish-terminal-image--timer nil)
  (pilish-terminal-image--invalidate)
  (dolist (hook '(post-command-hook window-buffer-change-functions
                  window-size-change-functions window-scroll-functions))
    (if pilish-terminal-image-mode
        (add-hook hook #'pilish-terminal-image--prune)
      (remove-hook hook #'pilish-terminal-image--prune)))
  (dolist (hook '(delete-frame-functions kill-emacs-hook))
    (if pilish-terminal-image-mode
        (add-hook hook #'pilish-terminal-image--invalidate)
      (remove-hook hook #'pilish-terminal-image--invalidate)))
  (when pilish-terminal-image-mode
    (setq pilish-terminal-image--timer
          (run-at-time 0.15 0.15 #'pilish-terminal-image--refresh))))

(provide 'pilish-terminal-image)
;;; pilish-terminal-image.el ends here
