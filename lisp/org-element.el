;;; org-element.el --- Parser And Applications for Org syntax

;; Copyright (C) 2012-2014 Free Software Foundation, Inc.

;; Author: Nicolas Goaziou <n.goaziou at gmail dot com>
;; Keywords: outlines, hypermedia, calendar, wp

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Org syntax can be divided into three categories: "Greater
;; elements", "Elements" and "Objects".
;;
;; Elements are related to the structure of the document.  Indeed, all
;; elements are a cover for the document: each position within belongs
;; to at least one element.
;;
;; An element always starts and ends at the beginning of a line.  With
;; a few exceptions (`clock', `headline', `inlinetask', `item',
;; `planning', `node-property', `section' and `table-row' types), it
;; can also accept a fixed set of keywords as attributes.  Those are
;; called "affiliated keywords" to distinguish them from other
;; keywords, which are full-fledged elements.  Almost all affiliated
;; keywords are referenced in `org-element-affiliated-keywords'; the
;; others are export attributes and start with "ATTR_" prefix.
;;
;; Element containing other elements (and only elements) are called
;; greater elements.  Concerned types are: `center-block', `drawer',
;; `dynamic-block', `footnote-definition', `headline', `inlinetask',
;; `item', `plain-list', `property-drawer', `quote-block', `section'
;; and `special-block'.
;;
;; Other element types are: `babel-call', `clock', `comment',
;; `comment-block', `diary-sexp', `example-block', `export-block',
;; `fixed-width', `horizontal-rule', `keyword', `latex-environment',
;; `node-property', `paragraph', `planning', `src-block', `table',
;; `table-row' and `verse-block'.  Among them, `paragraph' and
;; `verse-block' types can contain Org objects and plain text.
;;
;; Objects are related to document's contents.  Some of them are
;; recursive.  Associated types are of the following: `bold', `code',
;; `entity', `export-snippet', `footnote-reference',
;; `inline-babel-call', `inline-src-block', `italic',
;; `latex-fragment', `line-break', `link', `macro', `radio-target',
;; `statistics-cookie', `strike-through', `subscript', `superscript',
;; `table-cell', `target', `timestamp', `underline' and `verbatim'.
;;
;; Some elements also have special properties whose value can hold
;; objects themselves (e.g. an item tag or a headline name).  Such
;; values are called "secondary strings".  Any object belongs to
;; either an element or a secondary string.
;;
;; Notwithstanding affiliated keywords, each greater element, element
;; and object has a fixed set of properties attached to it.  Among
;; them, four are shared by all types: `:begin' and `:end', which
;; refer to the beginning and ending buffer positions of the
;; considered element or object, `:post-blank', which holds the number
;; of blank lines, or white spaces, at its end and `:parent' which
;; refers to the element or object containing it.  Greater elements,
;; elements and objects containing objects will also have
;; `:contents-begin' and `:contents-end' properties to delimit
;; contents.  Eventually, greater elements and elements accepting
;; affiliated keywords will have a `:post-affiliated' property,
;; referring to the buffer position after all such keywords.
;;
;; At the lowest level, a `:parent' property is also attached to any
;; string, as a text property.
;;
;; Lisp-wise, an element or an object can be represented as a list.
;; It follows the pattern (TYPE PROPERTIES CONTENTS), where:
;;   TYPE is a symbol describing the Org element or object.
;;   PROPERTIES is the property list attached to it.  See docstring of
;;              appropriate parsing function to get an exhaustive
;;              list.
;;   CONTENTS is a list of elements, objects or raw strings contained
;;            in the current element or object, when applicable.
;;
;; An Org buffer is a nested list of such elements and objects, whose
;; type is `org-data' and properties is nil.
;;
;; The first part of this file defines Org syntax, while the second
;; one provide accessors and setters functions.
;;
;; The next part implements a parser and an interpreter for each
;; element and object type in Org syntax.
;;
;; The following part creates a fully recursive buffer parser.  It
;; also provides a tool to map a function to elements or objects
;; matching some criteria in the parse tree.  Functions of interest
;; are `org-element-parse-buffer', `org-element-map' and, to a lesser
;; extent, `org-element-parse-secondary-string'.
;;
;; The penultimate part is the cradle of an interpreter for the
;; obtained parse tree: `org-element-interpret-data'.
;;
;; The library ends by furnishing `org-element-at-point' function, and
;; a way to give information about document structure around point
;; with `org-element-context'.  A cache mechanism is also provided for
;; these functions.


;;; Code:

(eval-when-compile (require 'cl))
(require 'org)
(require 'avl-tree)



;;; Definitions And Rules
;;
;; Define elements, greater elements and specify recursive objects,
;; along with the affiliated keywords recognized.  Also set up
;; restrictions on recursive objects combinations.
;;
;; These variables really act as a control center for the parsing
;; process.

(defconst org-element-paragraph-separate
  (concat "^\\(?:"
          ;; Headlines, inlinetasks.
          org-outline-regexp "\\|"
          ;; Footnote definitions.
	  "\\[\\(?:[0-9]+\\|fn:[-_[:word:]]+\\)\\]" "\\|"
	  ;; Diary sexps.
	  "%%(" "\\|"
          "[ \t]*\\(?:"
          ;; Empty lines.
          "$" "\\|"
	  ;; Tables (any type).
	  "\\(?:|\\|\\+-[-+]\\)" "\\|"
          ;; Blocks (any type), Babel calls and keywords.  Note: this
	  ;; is only an indication and need some thorough check.
          "#\\(?:[+ ]\\|$\\)" "\\|"
	  ;; Drawers (any type) and fixed-width areas.  This is also
	  ;; only an indication.
	  ":" "\\|"
          ;; Horizontal rules.
          "-\\{5,\\}[ \t]*$" "\\|"
          ;; LaTeX environments.
          "\\\\begin{\\([A-Za-z0-9]+\\*?\\)}" "\\|"
          ;; Planning and Clock lines.
          (regexp-opt (list org-scheduled-string
                            org-deadline-string
                            org-closed-string
                            org-clock-string))
          "\\|"
          ;; Lists.
          (let ((term (case org-plain-list-ordered-item-terminator
                        (?\) ")") (?. "\\.") (otherwise "[.)]")))
                (alpha (and org-list-allow-alphabetical "\\|[A-Za-z]")))
            (concat "\\(?:[-+*]\\|\\(?:[0-9]+" alpha "\\)" term "\\)"
                    "\\(?:[ \t]\\|$\\)"))
          "\\)\\)")
  "Regexp to separate paragraphs in an Org buffer.
In the case of lines starting with \"#\" and \":\", this regexp
is not sufficient to know if point is at a paragraph ending.  See
`org-element-paragraph-parser' for more information.")

(defconst org-element-all-elements
  '(babel-call center-block clock comment comment-block diary-sexp drawer
	       dynamic-block example-block export-block fixed-width
	       footnote-definition headline horizontal-rule inlinetask item
	       keyword latex-environment node-property paragraph plain-list
	       planning property-drawer quote-block section
	       special-block src-block table table-row verse-block)
  "Complete list of element types.")

(defconst org-element-greater-elements
  '(center-block drawer dynamic-block footnote-definition headline inlinetask
		 item plain-list property-drawer quote-block section
		 special-block table)
  "List of recursive element types aka Greater Elements.")

(defconst org-element-all-objects
  '(bold code entity export-snippet footnote-reference inline-babel-call
	 inline-src-block italic line-break latex-fragment link macro
	 radio-target statistics-cookie strike-through subscript superscript
	 table-cell target timestamp underline verbatim)
  "Complete list of object types.")

(defconst org-element-recursive-objects
  '(bold italic link subscript radio-target strike-through superscript
	 table-cell underline)
  "List of recursive object types.")

(defvar org-element-block-name-alist
  '(("CENTER" . org-element-center-block-parser)
    ("COMMENT" . org-element-comment-block-parser)
    ("EXAMPLE" . org-element-example-block-parser)
    ("QUOTE" . org-element-quote-block-parser)
    ("SRC" . org-element-src-block-parser)
    ("VERSE" . org-element-verse-block-parser))
  "Alist between block names and the associated parsing function.
Names must be uppercase.  Any block whose name has no association
is parsed with `org-element-special-block-parser'.")

(defconst org-element-link-type-is-file
  '("file" "file+emacs" "file+sys" "docview")
  "List of link types equivalent to \"file\".
Only these types can accept search options and an explicit
application to open them.")

(defconst org-element-affiliated-keywords
  '("CAPTION" "DATA" "HEADER" "HEADERS" "LABEL" "NAME" "PLOT" "RESNAME" "RESULT"
    "RESULTS" "SOURCE" "SRCNAME" "TBLNAME")
  "List of affiliated keywords as strings.
By default, all keywords setting attributes (e.g., \"ATTR_LATEX\")
are affiliated keywords and need not to be in this list.")

(defconst org-element-keyword-translation-alist
  '(("DATA" . "NAME")  ("LABEL" . "NAME") ("RESNAME" . "NAME")
    ("SOURCE" . "NAME") ("SRCNAME" . "NAME") ("TBLNAME" . "NAME")
    ("RESULT" . "RESULTS") ("HEADERS" . "HEADER"))
  "Alist of usual translations for keywords.
The key is the old name and the value the new one.  The property
holding their value will be named after the translated name.")

(defconst org-element-multiple-keywords '("CAPTION" "HEADER")
  "List of affiliated keywords that can occur more than once in an element.

Their value will be consed into a list of strings, which will be
returned as the value of the property.

This list is checked after translations have been applied.  See
`org-element-keyword-translation-alist'.

By default, all keywords setting attributes (e.g., \"ATTR_LATEX\")
allow multiple occurrences and need not to be in this list.")

(defconst org-element-parsed-keywords '("CAPTION")
  "List of affiliated keywords whose value can be parsed.

Their value will be stored as a secondary string: a list of
strings and objects.

This list is checked after translations have been applied.  See
`org-element-keyword-translation-alist'.")

(defconst org-element-dual-keywords '("CAPTION" "RESULTS")
  "List of affiliated keywords which can have a secondary value.

In Org syntax, they can be written with optional square brackets
before the colons.  For example, RESULTS keyword can be
associated to a hash value with the following:

  #+RESULTS[hash-string]: some-source

This list is checked after translations have been applied.  See
`org-element-keyword-translation-alist'.")

(defconst org-element-document-properties '("AUTHOR" "DATE" "TITLE")
  "List of properties associated to the whole document.
Any keyword in this list will have its value parsed and stored as
a secondary string.")

(defconst org-element--affiliated-re
  (format "[ \t]*#\\+\\(?:%s\\):\\(?: \\|$\\)"
	  (concat
	   ;; Dual affiliated keywords.
	   (format "\\(?1:%s\\)\\(?:\\[\\(.*\\)\\]\\)?"
		   (regexp-opt org-element-dual-keywords))
	   "\\|"
	   ;; Regular affiliated keywords.
	   (format "\\(?1:%s\\)"
		   (regexp-opt
		    (org-remove-if
		     #'(lambda (keyword)
			 (member keyword org-element-dual-keywords))
		     org-element-affiliated-keywords)))
	   "\\|"
	   ;; Export attributes.
	   "\\(?1:ATTR_[-_A-Za-z0-9]+\\)"))
  "Regexp matching any affiliated keyword.

Keyword name is put in match group 1.  Moreover, if keyword
belongs to `org-element-dual-keywords', put the dual value in
match group 2.

Don't modify it, set `org-element-affiliated-keywords' instead.")

(defconst org-element-object-restrictions
  (let* ((standard-set (remq 'table-cell org-element-all-objects))
	 (standard-set-no-line-break (remq 'line-break standard-set)))
    `((bold ,@standard-set)
      (footnote-reference ,@standard-set)
      (headline ,@standard-set-no-line-break)
      (inlinetask ,@standard-set-no-line-break)
      (italic ,@standard-set)
      (item ,@standard-set-no-line-break)
      (keyword ,@standard-set)
      ;; Ignore all links excepted plain links in a link description.
      ;; Also ignore radio-targets and line breaks.
      (link bold code entity export-snippet inline-babel-call inline-src-block
	    italic latex-fragment macro plain-link statistics-cookie
	    strike-through subscript superscript underline verbatim)
      (paragraph ,@standard-set)
      ;; Remove any variable object from radio target as it would
      ;; prevent it from being properly recognized.
      (radio-target bold code entity italic latex-fragment strike-through
		    subscript superscript underline superscript)
      (strike-through ,@standard-set)
      (subscript ,@standard-set)
      (superscript ,@standard-set)
      ;; Ignore inline babel call and inline src block as formulas are
      ;; possible.  Also ignore line breaks and statistics cookies.
      (table-cell bold code entity export-snippet footnote-reference italic
		  latex-fragment link macro radio-target strike-through
		  subscript superscript target timestamp underline verbatim)
      (table-row table-cell)
      (underline ,@standard-set)
      (verse-block ,@standard-set)))
  "Alist of objects restrictions.

key is an element or object type containing objects and value is
a list of types that can be contained within an element or object
of such type.

For example, in a `radio-target' object, one can only find
entities, latex-fragments, subscript, superscript and text
markup.

This alist also applies to secondary string.  For example, an
`headline' type element doesn't directly contain objects, but
still has an entry since one of its properties (`:title') does.")

(defconst org-element-secondary-value-alist
  '((headline . :title)
    (inlinetask . :title)
    (item . :tag)
    (footnote-reference . :inline-definition))
  "Alist between element types and location of secondary value.")

(defconst org-element-object-variables '(org-link-abbrev-alist-local)
  "List of buffer-local variables used when parsing objects.
These variables are copied to the temporary buffer created by
`org-export-secondary-string'.")



;;; Accessors and Setters
;;
;; Provide four accessors: `org-element-type', `org-element-property'
;; `org-element-contents' and `org-element-restriction'.
;;
;; Setter functions allow to modify elements by side effect.  There is
;; `org-element-put-property', `org-element-set-contents'.  These
;; low-level functions are useful to build a parse tree.
;;
;; `org-element-adopt-element', `org-element-set-element',
;; `org-element-extract-element' and `org-element-insert-before' are
;; high-level functions useful to modify a parse tree.
;;
;; `org-element-secondary-p' is a predicate used to know if a given
;; object belongs to a secondary string.

(defsubst org-element-type (element)
  "Return type of ELEMENT.

The function returns the type of the element or object provided.
It can also return the following special value:
  `plain-text'       for a string
  `org-data'         for a complete document
  nil                in any other case."
  (cond
   ((not (consp element)) (and (stringp element) 'plain-text))
   ((symbolp (car element)) (car element))))

(defsubst org-element-property (property element)
  "Extract the value from the PROPERTY of an ELEMENT."
  (if (stringp element) (get-text-property 0 property element)
    (plist-get (nth 1 element) property)))

(defsubst org-element-contents (element)
  "Extract contents from an ELEMENT."
  (cond ((not (consp element)) nil)
	((symbolp (car element)) (nthcdr 2 element))
	(t element)))

(defsubst org-element-restriction (element)
  "Return restriction associated to ELEMENT.
ELEMENT can be an element, an object or a symbol representing an
element or object type."
  (cdr (assq (if (symbolp element) element (org-element-type element))
	     org-element-object-restrictions)))

(defsubst org-element-put-property (element property value)
  "In ELEMENT set PROPERTY to VALUE.
Return modified element."
  (if (stringp element) (org-add-props element nil property value)
    (setcar (cdr element) (plist-put (nth 1 element) property value))
    element))

(defsubst org-element-set-contents (element &rest contents)
  "Set ELEMENT contents to CONTENTS.
Return modified element."
  (cond ((not element) (list contents))
	((not (symbolp (car element))) contents)
	((cdr element) (setcdr (cdr element) contents))
	(t (nconc element contents))))

(defun org-element-secondary-p (object)
  "Non-nil when OBJECT belongs to a secondary string.
Return value is the property name, as a keyword, or nil."
  (let* ((parent (org-element-property :parent object))
	 (property (cdr (assq (org-element-type parent)
			      org-element-secondary-value-alist))))
    (and property
	 (memq object (org-element-property property parent))
	 property)))

(defsubst org-element-adopt-elements (parent &rest children)
  "Append elements to the contents of another element.

PARENT is an element or object.  CHILDREN can be elements,
objects, or a strings.

The function takes care of setting `:parent' property for CHILD.
Return parent element."
  ;; Link every child to PARENT. If PARENT is nil, it is a secondary
  ;; string: parent is the list itself.
  (mapc (lambda (child)
	  (org-element-put-property child :parent (or parent children)))
	children)
  ;; Add CHILDREN at the end of PARENT contents.
  (when parent
    (apply 'org-element-set-contents
	   parent
	   (nconc (org-element-contents parent) children)))
  ;; Return modified PARENT element.
  (or parent children))

(defun org-element-extract-element (element)
  "Extract ELEMENT from parse tree.
Remove element from the parse tree by side-effect, and return it
with its `:parent' property stripped out."
  (let ((parent (org-element-property :parent element))
	(secondary (org-element-secondary-p element)))
    (if secondary
        (org-element-put-property
	 parent secondary
	 (delq element (org-element-property secondary parent)))
      (apply #'org-element-set-contents
	     parent
	     (delq element (org-element-contents parent))))
    ;; Return ELEMENT with its :parent removed.
    (org-element-put-property element :parent nil)))

(defun org-element-insert-before (element location)
  "Insert ELEMENT before LOCATION in parse tree.
LOCATION is an element, object or string within the parse tree.
Parse tree is modified by side effect."
  (let* ((parent (org-element-property :parent location))
	 (property (org-element-secondary-p location))
	 (siblings (if property (org-element-property property parent)
		     (org-element-contents parent)))
	 ;; Special case: LOCATION is the first element of an
	 ;; independent secondary string (e.g. :title property).  Add
	 ;; ELEMENT in-place.
	 (specialp (and (not property)
			(eq siblings parent)
			(eq (car parent) location))))
    ;; Install ELEMENT at the appropriate POSITION within SIBLINGS.
    (cond (specialp)
	  ((or (null siblings) (eq (car siblings) location))
	   (push element siblings))
	  ((null location) (nconc siblings (list element)))
	  (t (let ((previous (cadr (memq location (reverse siblings)))))
	       (if (not previous)
		   (error "No location found to insert element")
		 (let ((next (memq previous siblings)))
		   (setcdr next (cons element (cdr next))))))))
    ;; Store SIBLINGS at appropriate place in parse tree.
    (cond
     (specialp (setcdr parent (copy-sequence parent)) (setcar parent element))
     (property (org-element-put-property parent property siblings))
     (t (apply #'org-element-set-contents parent siblings)))
    ;; Set appropriate :parent property.
    (org-element-put-property element :parent parent)))

(defun org-element-set-element (old new)
  "Replace element or object OLD with element or object NEW.
The function takes care of setting `:parent' property for NEW."
  ;; Ensure OLD and NEW have the same parent.
  (org-element-put-property new :parent (org-element-property :parent old))
  (if (or (memq (org-element-type old) '(plain-text nil))
	  (memq (org-element-type new) '(plain-text nil)))
      ;; We cannot replace OLD with NEW since one of them is not an
      ;; object or element.  We take the long path.
      (progn (org-element-insert-before new old)
	     (org-element-extract-element old))
    ;; Since OLD is going to be changed into NEW by side-effect, first
    ;; make sure that every element or object within NEW has OLD as
    ;; parent.
    (dolist (blob (org-element-contents new))
      (org-element-put-property blob :parent old))
    ;; Transfer contents.
    (apply #'org-element-set-contents old (org-element-contents new))
    ;; Overwrite OLD's properties with NEW's.
    (setcar (cdr old) (nth 1 new))
    ;; Transfer type.
    (setcar old (car new))))



;;; Greater elements
;;
;; For each greater element type, we define a parser and an
;; interpreter.
;;
;; A parser returns the element or object as the list described above.
;; Most of them accepts no argument.  Though, exceptions exist.  Hence
;; every element containing a secondary string (see
;; `org-element-secondary-value-alist') will accept an optional
;; argument to toggle parsing of that secondary string.  Moreover,
;; `item' parser requires current list's structure as its first
;; element.
;;
;; An interpreter accepts two arguments: the list representation of
;; the element or object, and its contents.  The latter may be nil,
;; depending on the element or object considered.  It returns the
;; appropriate Org syntax, as a string.
;;
;; Parsing functions must follow the naming convention:
;; org-element-TYPE-parser, where TYPE is greater element's type, as
;; defined in `org-element-greater-elements'.
;;
;; Similarly, interpreting functions must follow the naming
;; convention: org-element-TYPE-interpreter.
;;
;; With the exception of `headline' and `item' types, greater elements
;; cannot contain other greater elements of their own type.
;;
;; Beside implementing a parser and an interpreter, adding a new
;; greater element requires to tweak `org-element--current-element'.
;; Moreover, the newly defined type must be added to both
;; `org-element-all-elements' and `org-element-greater-elements'.


;;;; Center Block

(defun org-element-center-block-parser (limit affiliated)
  "Parse a center block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `center-block' and CDR is a plist
containing `:begin', `:end', `:contents-begin', `:contents-end',
`:post-blank' and `:post-affiliated' keywords.

Assume point is at the beginning of the block."
  (let ((case-fold-search t))
    (if (not (save-excursion
	       (re-search-forward "^[ \t]*#\\+END_CENTER[ \t]*$" limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((block-end-line (match-beginning 0)))
	(let* ((begin (car affiliated))
	       (post-affiliated (point))
	       ;; Empty blocks have no contents.
	       (contents-begin (progn (forward-line)
				      (and (< (point) block-end-line)
					   (point))))
	       (contents-end (and contents-begin block-end-line))
	       (pos-before-blank (progn (goto-char block-end-line)
					(forward-line)
					(point)))
	       (end (save-excursion
		      (skip-chars-forward " \r\t\n" limit)
		      (if (eobp) (point) (line-beginning-position)))))
	  (list 'center-block
		(nconc
		 (list :begin begin
		       :end end
		       :contents-begin contents-begin
		       :contents-end contents-end
		       :post-blank (count-lines pos-before-blank end)
		       :post-affiliated post-affiliated)
		 (cdr affiliated))))))))

(defun org-element-center-block-interpreter (center-block contents)
  "Interpret CENTER-BLOCK element as Org syntax.
CONTENTS is the contents of the element."
  (format "#+BEGIN_CENTER\n%s#+END_CENTER" contents))


;;;; Drawer

(defun org-element-drawer-parser (limit affiliated)
  "Parse a drawer.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `drawer' and CDR is a plist containing
`:drawer-name', `:begin', `:end', `:contents-begin',
`:contents-end', `:post-blank' and `:post-affiliated' keywords.

Assume point is at beginning of drawer."
  (let ((case-fold-search t))
    (if (not (save-excursion (re-search-forward "^[ \t]*:END:[ \t]*$" limit t)))
	;; Incomplete drawer: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (save-excursion
	(let* ((drawer-end-line (match-beginning 0))
	       (name (progn (looking-at org-drawer-regexp)
			    (org-match-string-no-properties 1)))
	       (begin (car affiliated))
	       (post-affiliated (point))
	       ;; Empty drawers have no contents.
	       (contents-begin (progn (forward-line)
				      (and (< (point) drawer-end-line)
					   (point))))
	       (contents-end (and contents-begin drawer-end-line))
	       (pos-before-blank (progn (goto-char drawer-end-line)
					(forward-line)
					(point)))
	       (end (progn (skip-chars-forward " \r\t\n" limit)
			   (if (eobp) (point) (line-beginning-position)))))
	  (list 'drawer
		(nconc
		 (list :begin begin
		       :end end
		       :drawer-name name
		       :contents-begin contents-begin
		       :contents-end contents-end
		       :post-blank (count-lines pos-before-blank end)
		       :post-affiliated post-affiliated)
		 (cdr affiliated))))))))

(defun org-element-drawer-interpreter (drawer contents)
  "Interpret DRAWER element as Org syntax.
CONTENTS is the contents of the element."
  (format ":%s:\n%s:END:"
	  (org-element-property :drawer-name drawer)
	  contents))


;;;; Dynamic Block

(defun org-element-dynamic-block-parser (limit affiliated)
  "Parse a dynamic block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `dynamic-block' and CDR is a plist
containing `:block-name', `:begin', `:end', `:contents-begin',
`:contents-end', `:arguments', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at beginning of dynamic block."
  (let ((case-fold-search t))
    (if (not (save-excursion
	       (re-search-forward "^[ \t]*#\\+END:?[ \t]*$" limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((block-end-line (match-beginning 0)))
	(save-excursion
	  (let* ((name (progn (looking-at org-dblock-start-re)
			      (org-match-string-no-properties 1)))
		 (arguments (org-match-string-no-properties 3))
		 (begin (car affiliated))
		 (post-affiliated (point))
		 ;; Empty blocks have no contents.
		 (contents-begin (progn (forward-line)
					(and (< (point) block-end-line)
					     (point))))
		 (contents-end (and contents-begin block-end-line))
		 (pos-before-blank (progn (goto-char block-end-line)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'dynamic-block
		  (nconc
		   (list :begin begin
			 :end end
			 :block-name name
			 :arguments arguments
			 :contents-begin contents-begin
			 :contents-end contents-end
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-dynamic-block-interpreter (dynamic-block contents)
  "Interpret DYNAMIC-BLOCK element as Org syntax.
CONTENTS is the contents of the element."
  (format "#+BEGIN: %s%s\n%s#+END:"
	  (org-element-property :block-name dynamic-block)
	  (let ((args (org-element-property :arguments dynamic-block)))
	    (and args (concat " " args)))
	  contents))


;;;; Footnote Definition

(defun org-element-footnote-definition-parser (limit affiliated)
  "Parse a footnote definition.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `footnote-definition' and CDR is
a plist containing `:label', `:begin' `:end', `:contents-begin',
`:contents-end', `:post-blank' and `:post-affiliated' keywords.

Assume point is at the beginning of the footnote definition."
  (save-excursion
    (let* ((label (progn (looking-at org-footnote-definition-re)
			 (org-match-string-no-properties 1)))
	   (begin (car affiliated))
	   (post-affiliated (point))
	   (ending (save-excursion
		     (if (progn
			   (end-of-line)
			   (re-search-forward
			    (concat org-outline-regexp-bol "\\|"
				    org-footnote-definition-re "\\|"
				    "^\\([ \t]*\n\\)\\{2,\\}") limit 'move))
			 (match-beginning 0)
		       (point))))
	   (contents-begin (progn
			     (search-forward "]")
			     (skip-chars-forward " \r\t\n" ending)
			     (cond ((= (point) ending) nil)
				   ((= (line-beginning-position) begin) (point))
				   (t (line-beginning-position)))))
	   (contents-end (and contents-begin ending))
	   (end (progn (goto-char ending)
		       (skip-chars-forward " \r\t\n" limit)
		       (if (eobp) (point) (line-beginning-position)))))
      (list 'footnote-definition
	    (nconc
	     (list :label label
		   :begin begin
		   :end end
		   :contents-begin contents-begin
		   :contents-end contents-end
		   :post-blank (count-lines ending end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-footnote-definition-interpreter (footnote-definition contents)
  "Interpret FOOTNOTE-DEFINITION element as Org syntax.
CONTENTS is the contents of the footnote-definition."
  (concat (format "[%s]" (org-element-property :label footnote-definition))
	  " "
	  contents))


;;;; Headline

(defun org-element-headline-parser (limit &optional raw-secondary-p)
  "Parse a headline.

Return a list whose CAR is `headline' and CDR is a plist
containing `:raw-value', `:title', `:alt-title', `:begin',
`:end', `:pre-blank', `:contents-begin' and `:contents-end',
`:level', `:priority', `:tags', `:todo-keyword',`:todo-type',
`:scheduled', `:deadline', `:closed', `:archivedp', `:commentedp'
and `:footnote-section-p' keywords.

The plist also contains any property set in the property drawer,
with its name in upper cases and colons added at the
beginning (e.g., `:CUSTOM_ID').

LIMIT is a buffer position bounding the search.

When RAW-SECONDARY-P is non-nil, headline's title will not be
parsed as a secondary string, but as a plain string instead.

Assume point is at beginning of the headline."
  (save-excursion
    (let* ((components (org-heading-components))
	   (level (nth 1 components))
	   (todo (nth 2 components))
	   (todo-type
	    (and todo (if (member todo org-done-keywords) 'done 'todo)))
	   (tags (let ((raw-tags (nth 5 components)))
		   (and raw-tags (org-split-string raw-tags ":"))))
	   (raw-value (or (nth 4 components) ""))
	   (commentedp
	    (let ((case-fold-search nil))
	      (string-match (format "^%s\\( \\|$\\)" org-comment-string)
			    raw-value)))
	   (archivedp (member org-archive-tag tags))
	   (footnote-section-p (and org-footnote-section
				    (string= org-footnote-section raw-value)))
	   ;; Upcase property names.  It avoids confusion between
	   ;; properties obtained through property drawer and default
	   ;; properties from the parser (e.g. `:end' and :END:)
	   (standard-props
	    (let (plist)
	      (mapc
	       (lambda (p)
		 (setq plist
		       (plist-put plist
				  (intern (concat ":" (upcase (car p))))
				  (cdr p))))
	       (org-entry-properties nil 'standard))
	      plist))
	   (time-props
	    ;; Read time properties on the line below the headline.
	    (save-excursion
	      (when (progn (forward-line)
			   (looking-at org-planning-or-clock-line-re))
		(let ((end (line-end-position)) plist)
		  (while (re-search-forward
			  org-keyword-time-not-clock-regexp end t)
		    (goto-char (match-end 1))
		    (skip-chars-forward " \t")
		    (let ((keyword (match-string 1))
			  (time (org-element-timestamp-parser)))
		      (cond ((equal keyword org-scheduled-string)
			     (setq plist (plist-put plist :scheduled time)))
			    ((equal keyword org-deadline-string)
			     (setq plist (plist-put plist :deadline time)))
			    (t (setq plist (plist-put plist :closed time))))))
		  plist))))
	   (begin (point))
	   (end (min (save-excursion (org-end-of-subtree t t)) limit))
	   (pos-after-head (progn (forward-line) (point)))
	   (contents-begin (save-excursion
			     (skip-chars-forward " \r\t\n" end)
			     (and (/= (point) end) (line-beginning-position))))
	   (contents-end (and contents-begin
			      (progn (goto-char end)
				     (skip-chars-backward " \r\t\n")
				     (forward-line)
				     (point)))))
      ;; Clean RAW-VALUE from any comment string.
      (when commentedp
	(let ((case-fold-search nil))
	  (setq raw-value
		(replace-regexp-in-string
		 (concat (regexp-quote org-comment-string) "\\(?: \\|$\\)")
		 ""
		 raw-value))))
      ;; Clean TAGS from archive tag, if any.
      (when archivedp (setq tags (delete org-archive-tag tags)))
      (let ((headline
	     (list 'headline
		   (nconc
		    (list :raw-value raw-value
			  :begin begin
			  :end end
			  :pre-blank
			  (if (not contents-begin) 0
			    (count-lines pos-after-head contents-begin))
			  :contents-begin contents-begin
			  :contents-end contents-end
			  :level level
			  :priority (nth 3 components)
			  :tags tags
			  :todo-keyword todo
			  :todo-type todo-type
			  :post-blank (count-lines
				       (or contents-end pos-after-head)
				       end)
			  :footnote-section-p footnote-section-p
			  :archivedp archivedp
			  :commentedp commentedp)
		    time-props
		    standard-props))))
	(let ((alt-title (org-element-property :ALT_TITLE headline)))
	  (when alt-title
	    (org-element-put-property
	     headline :alt-title
	     (if raw-secondary-p alt-title
	       (org-element-parse-secondary-string
		alt-title (org-element-restriction 'headline) headline)))))
	(org-element-put-property
	 headline :title
	 (if raw-secondary-p raw-value
	   (org-element-parse-secondary-string
	    raw-value (org-element-restriction 'headline) headline)))))))

(defun org-element-headline-interpreter (headline contents)
  "Interpret HEADLINE element as Org syntax.
CONTENTS is the contents of the element."
  (let* ((level (org-element-property :level headline))
	 (todo (org-element-property :todo-keyword headline))
	 (priority (org-element-property :priority headline))
	 (title (org-element-interpret-data
		 (org-element-property :title headline)))
	 (tags (let ((tag-list (if (org-element-property :archivedp headline)
				   (cons org-archive-tag
					 (org-element-property :tags headline))
				 (org-element-property :tags headline))))
		 (and tag-list
		      (format ":%s:" (mapconcat 'identity tag-list ":")))))
	 (commentedp (org-element-property :commentedp headline))
	 (pre-blank (or (org-element-property :pre-blank headline) 0))
	 (heading (concat (make-string (org-reduced-level level) ?*)
			  (and todo (concat " " todo))
			  (and commentedp (concat " " org-comment-string))
			  (and priority
			       (format " [#%s]" (char-to-string priority)))
			  (cond ((and org-footnote-section
				      (org-element-property
				       :footnote-section-p headline))
				 (concat " " org-footnote-section))
				(title (concat " " title))))))
    (concat heading
	    ;; Align tags.
	    (when tags
	      (cond
	       ((zerop org-tags-column) (format " %s" tags))
	       ((< org-tags-column 0)
		(concat
		 (make-string
		  (max (- (+ org-tags-column (length heading) (length tags))) 1)
		  ? )
		 tags))
	       (t
		(concat
		 (make-string (max (- org-tags-column (length heading)) 1) ? )
		 tags))))
	    (make-string (1+ pre-blank) 10)
	    contents)))


;;;; Inlinetask

(defun org-element-inlinetask-parser (limit &optional raw-secondary-p)
  "Parse an inline task.

Return a list whose CAR is `inlinetask' and CDR is a plist
containing `:title', `:begin', `:end', `:contents-begin' and
`:contents-end', `:level', `:priority', `:raw-value', `:tags',
`:todo-keyword', `:todo-type', `:scheduled', `:deadline',
`:closed' and `:post-blank' keywords.

The plist also contains any property set in the property drawer,
with its name in upper cases and colons added at the
beginning (e.g., `:CUSTOM_ID').

When optional argument RAW-SECONDARY-P is non-nil, inline-task's
title will not be parsed as a secondary string, but as a plain
string instead.

Assume point is at beginning of the inline task."
  (save-excursion
    (let* ((begin (point))
	   (components (org-heading-components))
	   (todo (nth 2 components))
	   (todo-type (and todo
			   (if (member todo org-done-keywords) 'done 'todo)))
	   (tags (let ((raw-tags (nth 5 components)))
		   (and raw-tags (org-split-string raw-tags ":"))))
	   (raw-value (or (nth 4 components) ""))
	   ;; Upcase property names.  It avoids confusion between
	   ;; properties obtained through property drawer and default
	   ;; properties from the parser (e.g. `:end' and :END:)
	   (standard-props
	    (let (plist)
	      (mapc
	       (lambda (p)
		 (setq plist
		       (plist-put plist
				  (intern (concat ":" (upcase (car p))))
				  (cdr p))))
	       (org-entry-properties nil 'standard))
	      plist))
	   (time-props
	    ;; Read time properties on the line below the inlinetask
	    ;; opening string.
	    (save-excursion
	      (when (progn (forward-line)
			   (looking-at org-planning-or-clock-line-re))
		(let ((end (line-end-position)) plist)
		  (while (re-search-forward
			  org-keyword-time-not-clock-regexp end t)
		    (goto-char (match-end 1))
		    (skip-chars-forward " \t")
		    (let ((keyword (match-string 1))
			  (time (org-element-timestamp-parser)))
		      (cond ((equal keyword org-scheduled-string)
			     (setq plist (plist-put plist :scheduled time)))
			    ((equal keyword org-deadline-string)
			     (setq plist (plist-put plist :deadline time)))
			    (t (setq plist (plist-put plist :closed time))))))
		  plist))))
	   (task-end (save-excursion
		       (end-of-line)
		       (and (re-search-forward org-outline-regexp-bol limit t)
			    (org-looking-at-p "END[ \t]*$")
			    (line-beginning-position))))
	   (contents-begin (progn (forward-line)
				  (and task-end (< (point) task-end) (point))))
	   (contents-end (and contents-begin task-end))
	   (before-blank (if (not task-end) (point)
			   (goto-char task-end)
			   (forward-line)
			   (point)))
	   (end (progn (skip-chars-forward " \r\t\n" limit)
		       (if (eobp) (point) (line-beginning-position))))
	   (inlinetask
	    (list 'inlinetask
		  (nconc
		   (list :raw-value raw-value
			 :begin begin
			 :end end
			 :contents-begin contents-begin
			 :contents-end contents-end
			 :level (nth 1 components)
			 :priority (nth 3 components)
			 :tags tags
			 :todo-keyword todo
			 :todo-type todo-type
			 :post-blank (count-lines before-blank end))
		   time-props
		   standard-props))))
      (org-element-put-property
       inlinetask :title
       (if raw-secondary-p raw-value
	 (org-element-parse-secondary-string
	  raw-value
	  (org-element-restriction 'inlinetask)
	  inlinetask))))))

(defun org-element-inlinetask-interpreter (inlinetask contents)
  "Interpret INLINETASK element as Org syntax.
CONTENTS is the contents of inlinetask."
  (let* ((level (org-element-property :level inlinetask))
	 (todo (org-element-property :todo-keyword inlinetask))
	 (priority (org-element-property :priority inlinetask))
	 (title (org-element-interpret-data
		 (org-element-property :title inlinetask)))
	 (tags (let ((tag-list (org-element-property :tags inlinetask)))
		 (and tag-list
		      (format ":%s:" (mapconcat 'identity tag-list ":")))))
	 (task (concat (make-string level ?*)
		       (and todo (concat " " todo))
		       (and priority
			    (format " [#%s]" (char-to-string priority)))
		       (and title (concat " " title)))))
    (concat task
	    ;; Align tags.
	    (when tags
	      (cond
	       ((zerop org-tags-column) (format " %s" tags))
	       ((< org-tags-column 0)
		(concat
		 (make-string
		  (max (- (+ org-tags-column (length task) (length tags))) 1)
		  ? )
		 tags))
	       (t
		(concat
		 (make-string (max (- org-tags-column (length task)) 1) ? )
		 tags))))
	    ;; Prefer degenerate inlinetasks when there are no
	    ;; contents.
	    (when contents
	      (concat "\n"
		      contents
		      (make-string level ?*) " END")))))


;;;; Item

(defun org-element-item-parser (limit struct &optional raw-secondary-p)
  "Parse an item.

STRUCT is the structure of the plain list.

Return a list whose CAR is `item' and CDR is a plist containing
`:bullet', `:begin', `:end', `:contents-begin', `:contents-end',
`:checkbox', `:counter', `:tag', `:structure' and `:post-blank'
keywords.

When optional argument RAW-SECONDARY-P is non-nil, item's tag, if
any, will not be parsed as a secondary string, but as a plain
string instead.

Assume point is at the beginning of the item."
  (save-excursion
    (beginning-of-line)
    (looking-at org-list-full-item-re)
    (let* ((begin (point))
	   (bullet (org-match-string-no-properties 1))
	   (checkbox (let ((box (org-match-string-no-properties 3)))
		       (cond ((equal "[ ]" box) 'off)
			     ((equal "[X]" box) 'on)
			     ((equal "[-]" box) 'trans))))
	   (counter (let ((c (org-match-string-no-properties 2)))
		      (save-match-data
			(cond
			 ((not c) nil)
			 ((string-match "[A-Za-z]" c)
			  (- (string-to-char (upcase (match-string 0 c)))
			     64))
			 ((string-match "[0-9]+" c)
			  (string-to-number (match-string 0 c)))))))
	   (end (progn (goto-char (nth 6 (assq (point) struct)))
		       (unless (bolp) (forward-line))
		       (point)))
	   (contents-begin
	    (progn (goto-char
		    ;; Ignore tags in un-ordered lists: they are just
		    ;; a part of item's body.
		    (if (and (match-beginning 4)
			     (save-match-data (string-match "[.)]" bullet)))
			(match-beginning 4)
		      (match-end 0)))
		   (skip-chars-forward " \r\t\n" limit)
		   ;; If first line isn't empty, contents really start
		   ;; at the text after item's meta-data.
		   (if (= (point-at-bol) begin) (point) (point-at-bol))))
	   (contents-end (progn (goto-char end)
				(skip-chars-backward " \r\t\n")
				(forward-line)
				(point)))
	   (item
	    (list 'item
		  (list :bullet bullet
			:begin begin
			:end end
			;; CONTENTS-BEGIN and CONTENTS-END may be
			;; mixed up in the case of an empty item
			;; separated from the next by a blank line.
			;; Thus ensure the former is always the
			;; smallest.
			:contents-begin (min contents-begin contents-end)
			:contents-end (max contents-begin contents-end)
			:checkbox checkbox
			:counter counter
			:structure struct
			:post-blank (count-lines contents-end end)))))
      (org-element-put-property
       item :tag
       (let ((raw-tag (org-list-get-tag begin struct)))
	 (and raw-tag
	      (if raw-secondary-p raw-tag
		(org-element-parse-secondary-string
		 raw-tag (org-element-restriction 'item) item))))))))

(defun org-element-item-interpreter (item contents)
  "Interpret ITEM element as Org syntax.
CONTENTS is the contents of the element."
  (let* ((bullet (let ((bullet (org-element-property :bullet item)))
		   (org-list-bullet-string
		    (cond ((not (string-match "[0-9a-zA-Z]" bullet)) "- ")
			  ((eq org-plain-list-ordered-item-terminator ?\)) "1)")
			  (t "1.")))))
	 (checkbox (org-element-property :checkbox item))
	 (counter (org-element-property :counter item))
	 (tag (let ((tag (org-element-property :tag item)))
		(and tag (org-element-interpret-data tag))))
	 ;; Compute indentation.
	 (ind (make-string (length bullet) 32))
	 (item-starts-with-par-p
	  (eq (org-element-type (car (org-element-contents item)))
	      'paragraph)))
    ;; Indent contents.
    (concat
     bullet
     (and counter (format "[@%d] " counter))
     (case checkbox
       (on "[X] ")
       (off "[ ] ")
       (trans "[-] "))
     (and tag (format "%s :: " tag))
     (when contents
       (let ((contents (replace-regexp-in-string
			"\\(^\\)[ \t]*\\S-" ind contents nil nil 1)))
	 (if item-starts-with-par-p (org-trim contents)
	   (concat "\n" contents)))))))


;;;; Plain List

(defun org-element--list-struct (limit)
  ;; Return structure of list at point.  Internal function.  See
  ;; `org-list-struct' for details.
  (let ((case-fold-search t)
	(top-ind limit)
	(item-re (org-item-re))
	(inlinetask-re (and (featurep 'org-inlinetask) "^\\*+ "))
	items struct)
    (save-excursion
      (catch 'exit
	(while t
	  (cond
	   ;; At limit: end all items.
	   ((>= (point) limit)
	    (throw 'exit
		   (let ((end (progn (skip-chars-backward " \r\t\n")
				     (forward-line)
				     (point))))
		     (dolist (item items (sort (nconc items struct)
					       'car-less-than-car))
		       (setcar (nthcdr 6 item) end)))))
	   ;; At list end: end all items.
	   ((looking-at org-list-end-re)
	    (throw 'exit (dolist (item items (sort (nconc items struct)
						   'car-less-than-car))
			   (setcar (nthcdr 6 item) (point)))))
	   ;; At a new item: end previous sibling.
	   ((looking-at item-re)
	    (let ((ind (save-excursion (skip-chars-forward " \t")
				       (current-column))))
	      (setq top-ind (min top-ind ind))
	      (while (and items (<= ind (nth 1 (car items))))
		(let ((item (pop items)))
		  (setcar (nthcdr 6 item) (point))
		  (push item struct)))
	      (push (progn (looking-at org-list-full-item-re)
			   (let ((bullet (match-string-no-properties 1)))
			     (list (point)
				   ind
				   bullet
				   (match-string-no-properties 2) ; counter
				   (match-string-no-properties 3) ; checkbox
				   ;; Description tag.
				   (and (save-match-data
					  (string-match "[-+*]" bullet))
					(match-string-no-properties 4))
				   ;; Ending position, unknown so far.
				   nil)))
		    items))
	    (forward-line 1))
	   ;; Skip empty lines.
	   ((looking-at "^[ \t]*$") (forward-line))
	   ;; Skip inline tasks and blank lines along the way.
	   ((and inlinetask-re (looking-at inlinetask-re))
	    (forward-line)
	    (let ((origin (point)))
	      (when (re-search-forward inlinetask-re limit t)
		(if (org-looking-at-p "END[ \t]*$") (forward-line)
		  (goto-char origin)))))
	   ;; At some text line.  Check if it ends any previous item.
	   (t
	    (let ((ind (progn (skip-chars-forward " \t") (current-column))))
	      (when (<= ind top-ind)
		(skip-chars-backward " \r\t\n")
		(forward-line))
	      (while (<= ind (nth 1 (car items)))
		(let ((item (pop items)))
		  (setcar (nthcdr 6 item) (line-beginning-position))
		  (push item struct)
		  (unless items
		    (throw 'exit (sort struct 'car-less-than-car))))))
	    ;; Skip blocks (any type) and drawers contents.
	    (cond
	     ((and (looking-at "#\\+BEGIN\\(:\\|_\\S-+\\)")
		   (re-search-forward
		    (format "^[ \t]*#\\+END%s[ \t]*$" (match-string 1))
		    limit t)))
	     ((and (looking-at org-drawer-regexp)
		   (re-search-forward "^[ \t]*:END:[ \t]*$" limit t))))
	    (forward-line))))))))

(defun org-element-plain-list-parser (limit affiliated structure)
  "Parse a plain list.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.  STRUCTURE is the structure of the plain list being
parsed.

Return a list whose CAR is `plain-list' and CDR is a plist
containing `:type', `:begin', `:end', `:contents-begin' and
`:contents-end', `:structure', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at the beginning of the list."
  (save-excursion
    (let* ((struct (or structure (org-element--list-struct limit)))
	   (type (cond ((org-looking-at-p "[ \t]*[A-Za-z0-9]") 'ordered)
		       ((nth 5 (assq (point) struct)) 'descriptive)
		       (t 'unordered)))
	   (contents-begin (point))
	   (begin (car affiliated))
	   (contents-end (let* ((item (assq contents-begin struct))
				(ind (nth 1 item))
				(pos (nth 6 item)))
			   (while (and (setq item (assq pos struct))
				       (= (nth 1 item) ind))
			     (setq pos (nth 6 item)))
			   pos))
	   (end (progn (goto-char contents-end)
		       (skip-chars-forward " \r\t\n" limit)
		       (if (= (point) limit) limit (line-beginning-position)))))
      ;; Return value.
      (list 'plain-list
	    (nconc
	     (list :type type
		   :begin begin
		   :end end
		   :contents-begin contents-begin
		   :contents-end contents-end
		   :structure struct
		   :post-blank (count-lines contents-end end)
		   :post-affiliated contents-begin)
	     (cdr affiliated))))))

(defun org-element-plain-list-interpreter (plain-list contents)
  "Interpret PLAIN-LIST element as Org syntax.
CONTENTS is the contents of the element."
  (with-temp-buffer
    (insert contents)
    (goto-char (point-min))
    (org-list-repair)
    (buffer-string)))


;;;; Property Drawer

(defun org-element-property-drawer-parser (limit affiliated)
  "Parse a property drawer.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `property-drawer' and CDR is a plist
containing `:begin', `:end', `:contents-begin', `:contents-end',
`:post-blank' and `:post-affiliated' keywords.

Assume point is at the beginning of the property drawer."
  (save-excursion
    (let ((case-fold-search t))
      (if (not (save-excursion
		 (re-search-forward "^[ \t]*:END:[ \t]*$" limit t)))
	  ;; Incomplete drawer: parse it as a paragraph.
	  (org-element-paragraph-parser limit affiliated)
	(save-excursion
	  (let* ((drawer-end-line (match-beginning 0))
		 (begin (car affiliated))
		 (post-affiliated (point))
		 (contents-begin (progn (forward-line)
					(and (< (point) drawer-end-line)
					     (point))))
		 (contents-end (and contents-begin drawer-end-line))
		 (pos-before-blank (progn (goto-char drawer-end-line)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'property-drawer
		  (nconc
		   (list :begin begin
			 :end end
			 :contents-begin contents-begin
			 :contents-end contents-end
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-property-drawer-interpreter (property-drawer contents)
  "Interpret PROPERTY-DRAWER element as Org syntax.
CONTENTS is the properties within the drawer."
  (format ":PROPERTIES:\n%s:END:" contents))


;;;; Quote Block

(defun org-element-quote-block-parser (limit affiliated)
  "Parse a quote block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `quote-block' and CDR is a plist
containing `:begin', `:end', `:contents-begin', `:contents-end',
`:post-blank' and `:post-affiliated' keywords.

Assume point is at the beginning of the block."
  (let ((case-fold-search t))
    (if (not (save-excursion
	       (re-search-forward "^[ \t]*#\\+END_QUOTE[ \t]*$" limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((block-end-line (match-beginning 0)))
	(save-excursion
	  (let* ((begin (car affiliated))
		 (post-affiliated (point))
		 ;; Empty blocks have no contents.
		 (contents-begin (progn (forward-line)
					(and (< (point) block-end-line)
					     (point))))
		 (contents-end (and contents-begin block-end-line))
		 (pos-before-blank (progn (goto-char block-end-line)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'quote-block
		  (nconc
		   (list :begin begin
			 :end end
			 :contents-begin contents-begin
			 :contents-end contents-end
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-quote-block-interpreter (quote-block contents)
  "Interpret QUOTE-BLOCK element as Org syntax.
CONTENTS is the contents of the element."
  (format "#+BEGIN_QUOTE\n%s#+END_QUOTE" contents))


;;;; Section

(defun org-element-section-parser (limit)
  "Parse a section.

LIMIT bounds the search.

Return a list whose CAR is `section' and CDR is a plist
containing `:begin', `:end', `:contents-begin', `contents-end'
and `:post-blank' keywords."
  (save-excursion
    ;; Beginning of section is the beginning of the first non-blank
    ;; line after previous headline.
    (let ((begin (point))
	  (end (progn (org-with-limited-levels (outline-next-heading))
		      (point)))
	  (pos-before-blank (progn (skip-chars-backward " \r\t\n")
				   (forward-line)
				   (point))))
      (list 'section
	    (list :begin begin
		  :end end
		  :contents-begin begin
		  :contents-end pos-before-blank
		  :post-blank (count-lines pos-before-blank end))))))

(defun org-element-section-interpreter (section contents)
  "Interpret SECTION element as Org syntax.
CONTENTS is the contents of the element."
  contents)


;;;; Special Block

(defun org-element-special-block-parser (limit affiliated)
  "Parse a special block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `special-block' and CDR is a plist
containing `:type', `:begin', `:end', `:contents-begin',
`:contents-end', `:post-blank' and `:post-affiliated' keywords.

Assume point is at the beginning of the block."
  (let* ((case-fold-search t)
	 (type (progn (looking-at "[ \t]*#\\+BEGIN_\\(\\S-+\\)")
		      (upcase (match-string-no-properties 1)))))
    (if (not (save-excursion
	       (re-search-forward
		(format "^[ \t]*#\\+END_%s[ \t]*$" (regexp-quote type))
		limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((block-end-line (match-beginning 0)))
	(save-excursion
	  (let* ((begin (car affiliated))
		 (post-affiliated (point))
		 ;; Empty blocks have no contents.
		 (contents-begin (progn (forward-line)
					(and (< (point) block-end-line)
					     (point))))
		 (contents-end (and contents-begin block-end-line))
		 (pos-before-blank (progn (goto-char block-end-line)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'special-block
		  (nconc
		   (list :type type
			 :begin begin
			 :end end
			 :contents-begin contents-begin
			 :contents-end contents-end
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-special-block-interpreter (special-block contents)
  "Interpret SPECIAL-BLOCK element as Org syntax.
CONTENTS is the contents of the element."
  (let ((block-type (org-element-property :type special-block)))
    (format "#+BEGIN_%s\n%s#+END_%s" block-type contents block-type)))



;;; Elements
;;
;; For each element, a parser and an interpreter are also defined.
;; Both follow the same naming convention used for greater elements.
;;
;; Also, as for greater elements, adding a new element type is done
;; through the following steps: implement a parser and an interpreter,
;; tweak `org-element--current-element' so that it recognizes the new
;; type and add that new type to `org-element-all-elements'.
;;
;; As a special case, when the newly defined type is a block type,
;; `org-element-block-name-alist' has to be modified accordingly.


;;;; Babel Call

(defun org-element-babel-call-parser (limit affiliated)
  "Parse a babel call.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `babel-call' and CDR is a plist
containing `:begin', `:end', `:value', `:post-blank' and
`:post-affiliated' as keywords."
  (save-excursion
    (let ((begin (car affiliated))
	  (post-affiliated (point))
	  (value (progn (let ((case-fold-search t))
			  (re-search-forward "call:[ \t]*" nil t))
			(buffer-substring-no-properties (point)
							(line-end-position))))
	  (pos-before-blank (progn (forward-line) (point)))
	  (end (progn (skip-chars-forward " \r\t\n" limit)
		      (if (eobp) (point) (line-beginning-position)))))
      (list 'babel-call
	    (nconc
	     (list :begin begin
		   :end end
		   :value value
		   :post-blank (count-lines pos-before-blank end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-babel-call-interpreter (babel-call contents)
  "Interpret BABEL-CALL element as Org syntax.
CONTENTS is nil."
  (concat "#+CALL: " (org-element-property :value babel-call)))


;;;; Clock

(defun org-element-clock-parser (limit)
  "Parse a clock.

LIMIT bounds the search.

Return a list whose CAR is `clock' and CDR is a plist containing
`:status', `:value', `:time', `:begin', `:end' and `:post-blank'
as keywords."
  (save-excursion
    (let* ((case-fold-search nil)
	   (begin (point))
	   (value (progn (search-forward org-clock-string (line-end-position) t)
			 (skip-chars-forward " \t")
			 (org-element-timestamp-parser)))
	   (duration (and (search-forward " => " (line-end-position) t)
			  (progn (skip-chars-forward " \t")
				 (looking-at "\\(\\S-+\\)[ \t]*$"))
			  (org-match-string-no-properties 1)))
	   (status (if duration 'closed 'running))
	   (post-blank (let ((before-blank (progn (forward-line) (point))))
			 (skip-chars-forward " \r\t\n" limit)
			 (skip-chars-backward " \t")
			 (unless (bolp) (end-of-line))
			 (count-lines before-blank (point))))
	   (end (point)))
      (list 'clock
	    (list :status status
		  :value value
		  :duration duration
		  :begin begin
		  :end end
		  :post-blank post-blank)))))

(defun org-element-clock-interpreter (clock contents)
  "Interpret CLOCK element as Org syntax.
CONTENTS is nil."
  (concat org-clock-string " "
	  (org-element-timestamp-interpreter
	   (org-element-property :value clock) nil)
	  (let ((duration (org-element-property :duration clock)))
	    (and duration
		 (concat " => "
			 (apply 'format
				"%2s:%02s"
				(org-split-string duration ":")))))))


;;;; Comment

(defun org-element-comment-parser (limit affiliated)
  "Parse a comment.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `comment' and CDR is a plist
containing `:begin', `:end', `:value', `:post-blank',
`:post-affiliated' keywords.

Assume point is at comment beginning."
  (save-excursion
    (let* ((begin (car affiliated))
	   (post-affiliated (point))
	   (value (prog2 (looking-at "[ \t]*# ?")
		      (buffer-substring-no-properties
		       (match-end 0) (line-end-position))
		    (forward-line)))
	   (com-end
	    ;; Get comments ending.
	    (progn
	      (while (and (< (point) limit) (looking-at "[ \t]*#\\( \\|$\\)"))
		;; Accumulate lines without leading hash and first
		;; whitespace.
		(setq value
		      (concat value
			      "\n"
			      (buffer-substring-no-properties
			       (match-end 0) (line-end-position))))
		(forward-line))
	      (point)))
	   (end (progn (goto-char com-end)
		       (skip-chars-forward " \r\t\n" limit)
		       (if (eobp) (point) (line-beginning-position)))))
      (list 'comment
	    (nconc
	     (list :begin begin
		   :end end
		   :value value
		   :post-blank (count-lines com-end end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-comment-interpreter (comment contents)
  "Interpret COMMENT element as Org syntax.
CONTENTS is nil."
  (replace-regexp-in-string "^" "# " (org-element-property :value comment)))


;;;; Comment Block

(defun org-element-comment-block-parser (limit affiliated)
  "Parse an export block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `comment-block' and CDR is a plist
containing `:begin', `:end', `:value', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at comment block beginning."
  (let ((case-fold-search t))
    (if (not (save-excursion
	       (re-search-forward "^[ \t]*#\\+END_COMMENT[ \t]*$" limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((contents-end (match-beginning 0)))
	(save-excursion
	  (let* ((begin (car affiliated))
		 (post-affiliated (point))
		 (contents-begin (progn (forward-line) (point)))
		 (pos-before-blank (progn (goto-char contents-end)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position))))
		 (value (buffer-substring-no-properties
			 contents-begin contents-end)))
	    (list 'comment-block
		  (nconc
		   (list :begin begin
			 :end end
			 :value value
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-comment-block-interpreter (comment-block contents)
  "Interpret COMMENT-BLOCK element as Org syntax.
CONTENTS is nil."
  (format "#+BEGIN_COMMENT\n%s#+END_COMMENT"
	  (org-remove-indentation (org-element-property :value comment-block))))


;;;; Diary Sexp

(defun org-element-diary-sexp-parser (limit affiliated)
  "Parse a diary sexp.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `diary-sexp' and CDR is a plist
containing `:begin', `:end', `:value', `:post-blank' and
`:post-affiliated' keywords."
  (save-excursion
    (let ((begin (car affiliated))
	  (post-affiliated (point))
	  (value (progn (looking-at "\\(%%(.*\\)[ \t]*$")
			(org-match-string-no-properties 1)))
	  (pos-before-blank (progn (forward-line) (point)))
	  (end (progn (skip-chars-forward " \r\t\n" limit)
		      (if (eobp) (point) (line-beginning-position)))))
      (list 'diary-sexp
	    (nconc
	     (list :value value
		   :begin begin
		   :end end
		   :post-blank (count-lines pos-before-blank end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-diary-sexp-interpreter (diary-sexp contents)
  "Interpret DIARY-SEXP as Org syntax.
CONTENTS is nil."
  (org-element-property :value diary-sexp))


;;;; Example Block

(defun org-element-example-block-parser (limit affiliated)
  "Parse an example block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `example-block' and CDR is a plist
containing `:begin', `:end', `:number-lines', `:preserve-indent',
`:retain-labels', `:use-labels', `:label-fmt', `:switches',
`:value', `:post-blank' and `:post-affiliated' keywords."
  (let ((case-fold-search t))
    (if (not (save-excursion
	       (re-search-forward "^[ \t]*#\\+END_EXAMPLE[ \t]*$" limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((contents-end (match-beginning 0)))
	(save-excursion
	  (let* ((switches
		  (progn
		    (looking-at "^[ \t]*#\\+BEGIN_EXAMPLE\\(?: +\\(.*\\)\\)?")
		    (org-match-string-no-properties 1)))
		 ;; Switches analysis
		 (number-lines
		  (cond ((not switches) nil)
			((string-match "-n\\>" switches) 'new)
			((string-match "+n\\>" switches) 'continued)))
		 (preserve-indent
		  (and switches (string-match "-i\\>" switches)))
		 ;; Should labels be retained in (or stripped from) example
		 ;; blocks?
		 (retain-labels
		  (or (not switches)
		      (not (string-match "-r\\>" switches))
		      (and number-lines (string-match "-k\\>" switches))))
		 ;; What should code-references use - labels or
		 ;; line-numbers?
		 (use-labels
		  (or (not switches)
		      (and retain-labels
			   (not (string-match "-k\\>" switches)))))
		 (label-fmt
		  (and switches
		       (string-match "-l +\"\\([^\"\n]+\\)\"" switches)
		       (match-string 1 switches)))
		 ;; Standard block parsing.
		 (begin (car affiliated))
		 (post-affiliated (point))
		 (block-ind (progn (skip-chars-forward " \t") (current-column)))
		 (contents-begin (progn (forward-line) (point)))
		 (value (org-element-remove-indentation
			 (org-unescape-code-in-string
			  (buffer-substring-no-properties
			   contents-begin contents-end))
			 block-ind))
		 (pos-before-blank (progn (goto-char contents-end)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'example-block
		  (nconc
		   (list :begin begin
			 :end end
			 :value value
			 :switches switches
			 :number-lines number-lines
			 :preserve-indent preserve-indent
			 :retain-labels retain-labels
			 :use-labels use-labels
			 :label-fmt label-fmt
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-example-block-interpreter (example-block contents)
  "Interpret EXAMPLE-BLOCK element as Org syntax.
CONTENTS is nil."
  (let ((switches (org-element-property :switches example-block))
	(value (org-element-property :value example-block)))
    (concat "#+BEGIN_EXAMPLE" (and switches (concat " " switches)) "\n"
	    (org-escape-code-in-string
	     (if (or org-src-preserve-indentation
		     (org-element-property :preserve-indent example-block))
		 value
	       (org-element-remove-indentation value)))
	    "#+END_EXAMPLE")))


;;;; Export Block

(defun org-element-export-block-parser (limit affiliated)
  "Parse an export block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `export-block' and CDR is a plist
containing `:begin', `:end', `:type', `:value', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at export-block beginning."
  (let* ((case-fold-search t)
	 (type (progn (looking-at "[ \t]*#\\+BEGIN_\\(\\S-+\\)")
		      (upcase (org-match-string-no-properties 1)))))
    (if (not (save-excursion
	       (re-search-forward
		(format "^[ \t]*#\\+END_%s[ \t]*$" type) limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((contents-end (match-beginning 0)))
	(save-excursion
	  (let* ((begin (car affiliated))
		 (post-affiliated (point))
		 (contents-begin (progn (forward-line) (point)))
		 (pos-before-blank (progn (goto-char contents-end)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position))))
		 (value (buffer-substring-no-properties contents-begin
							contents-end)))
	    (list 'export-block
		  (nconc
		   (list :begin begin
			 :end end
			 :type type
			 :value value
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-export-block-interpreter (export-block contents)
  "Interpret EXPORT-BLOCK element as Org syntax.
CONTENTS is nil."
  (let ((type (org-element-property :type export-block)))
    (concat (format "#+BEGIN_%s\n" type)
	    (org-element-property :value export-block)
	    (format "#+END_%s" type))))


;;;; Fixed-width

(defun org-element-fixed-width-parser (limit affiliated)
  "Parse a fixed-width section.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `fixed-width' and CDR is a plist
containing `:begin', `:end', `:value', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at the beginning of the fixed-width area."
  (save-excursion
    (let* ((begin (car affiliated))
	   (post-affiliated (point))
	   value
	   (end-area
	    (progn
	      (while (and (< (point) limit)
			  (looking-at "[ \t]*:\\( \\|$\\)"))
		;; Accumulate text without starting colons.
		(setq value
		      (concat value
			      (buffer-substring-no-properties
			       (match-end 0) (point-at-eol))
			      "\n"))
		(forward-line))
	      (point)))
	   (end (progn (skip-chars-forward " \r\t\n" limit)
		       (if (eobp) (point) (line-beginning-position)))))
      (list 'fixed-width
	    (nconc
	     (list :begin begin
		   :end end
		   :value value
		   :post-blank (count-lines end-area end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-fixed-width-interpreter (fixed-width contents)
  "Interpret FIXED-WIDTH element as Org syntax.
CONTENTS is nil."
  (let ((value (org-element-property :value fixed-width)))
    (and value
	 (replace-regexp-in-string
	  "^" ": "
	  (if (string-match "\n\\'" value) (substring value 0 -1) value)))))


;;;; Horizontal Rule

(defun org-element-horizontal-rule-parser (limit affiliated)
  "Parse an horizontal rule.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `horizontal-rule' and CDR is a plist
containing `:begin', `:end', `:post-blank' and `:post-affiliated'
keywords."
  (save-excursion
    (let ((begin (car affiliated))
	  (post-affiliated (point))
	  (post-hr (progn (forward-line) (point)))
	  (end (progn (skip-chars-forward " \r\t\n" limit)
		      (if (eobp) (point) (line-beginning-position)))))
      (list 'horizontal-rule
	    (nconc
	     (list :begin begin
		   :end end
		   :post-blank (count-lines post-hr end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-horizontal-rule-interpreter (horizontal-rule contents)
  "Interpret HORIZONTAL-RULE element as Org syntax.
CONTENTS is nil."
  "-----")


;;;; Keyword

(defun org-element-keyword-parser (limit affiliated)
  "Parse a keyword at point.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `keyword' and CDR is a plist
containing `:key', `:value', `:begin', `:end', `:post-blank' and
`:post-affiliated' keywords."
  (save-excursion
    ;; An orphaned affiliated keyword is considered as a regular
    ;; keyword.  In this case AFFILIATED is nil, so we take care of
    ;; this corner case.
    (let ((begin (or (car affiliated) (point)))
	  (post-affiliated (point))
	  (key (progn (looking-at "[ \t]*#\\+\\(\\S-+*\\):")
		      (upcase (org-match-string-no-properties 1))))
	  (value (org-trim (buffer-substring-no-properties
			    (match-end 0) (point-at-eol))))
	  (pos-before-blank (progn (forward-line) (point)))
	  (end (progn (skip-chars-forward " \r\t\n" limit)
		      (if (eobp) (point) (line-beginning-position)))))
      (list 'keyword
	    (nconc
	     (list :key key
		   :value value
		   :begin begin
		   :end end
		   :post-blank (count-lines pos-before-blank end)
		   :post-affiliated post-affiliated)
	     (cdr affiliated))))))

(defun org-element-keyword-interpreter (keyword contents)
  "Interpret KEYWORD element as Org syntax.
CONTENTS is nil."
  (format "#+%s: %s"
	  (org-element-property :key keyword)
	  (org-element-property :value keyword)))


;;;; Latex Environment

(defun org-element-latex-environment-parser (limit affiliated)
  "Parse a LaTeX environment.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `latex-environment' and CDR is a plist
containing `:begin', `:end', `:value', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at the beginning of the latex environment."
  (save-excursion
    (let ((case-fold-search t)
	  (code-begin (point)))
      (looking-at "[ \t]*\\\\begin{\\([A-Za-z0-9]+\\*?\\)}")
      (if (not (re-search-forward (format "^[ \t]*\\\\end{%s}[ \t]*$"
					  (regexp-quote (match-string 1)))
				  limit t))
	  ;; Incomplete latex environment: parse it as a paragraph.
	  (org-element-paragraph-parser limit affiliated)
	(let* ((code-end (progn (forward-line) (point)))
	       (begin (car affiliated))
	       (value (buffer-substring-no-properties code-begin code-end))
	       (end (progn (skip-chars-forward " \r\t\n" limit)
			   (if (eobp) (point) (line-beginning-position)))))
	  (list 'latex-environment
		(nconc
		 (list :begin begin
		       :end end
		       :value value
		       :post-blank (count-lines code-end end)
		       :post-affiliated code-begin)
		 (cdr affiliated))))))))

(defun org-element-latex-environment-interpreter (latex-environment contents)
  "Interpret LATEX-ENVIRONMENT element as Org syntax.
CONTENTS is nil."
  (org-element-property :value latex-environment))


;;;; Node Property

(defun org-element-node-property-parser (limit)
  "Parse a node-property at point.

LIMIT bounds the search.

Return a list whose CAR is `node-property' and CDR is a plist
containing `:key', `:value', `:begin', `:end' and `:post-blank'
keywords."
  (save-excursion
    (looking-at org-property-re)
    (let ((case-fold-search t)
	  (begin (point))
	  (key   (org-match-string-no-properties 2))
	  (value (org-match-string-no-properties 3))
	  (pos-before-blank (progn (forward-line) (point)))
	  (end (progn (skip-chars-forward " \r\t\n" limit)
		      (if (eobp) (point) (point-at-bol)))))
      (list 'node-property
	    (list :key key
		  :value value
		  :begin begin
		  :end end
		  :post-blank (count-lines pos-before-blank end))))))

(defun org-element-node-property-interpreter (node-property contents)
  "Interpret NODE-PROPERTY element as Org syntax.
CONTENTS is nil."
  (format org-property-format
	  (format ":%s:" (org-element-property :key node-property))
	  (org-element-property :value node-property)))


;;;; Paragraph

(defun org-element-paragraph-parser (limit affiliated)
  "Parse a paragraph.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `paragraph' and CDR is a plist
containing `:begin', `:end', `:contents-begin' and
`:contents-end', `:post-blank' and `:post-affiliated' keywords.

Assume point is at the beginning of the paragraph."
  (save-excursion
    (let* ((begin (car affiliated))
	   (contents-begin (point))
	   (before-blank
	    (let ((case-fold-search t))
	      (end-of-line)
	      (if (not (re-search-forward
			org-element-paragraph-separate limit 'm))
		  limit
		;; A matching `org-element-paragraph-separate' is not
		;; necessarily the end of the paragraph.  In
		;; particular, lines starting with # or : as a first
		;; non-space character are ambiguous.  We have to
		;; check if they are valid Org syntax (e.g., not an
		;; incomplete keyword).
		(beginning-of-line)
		(while (not
			(or
			 ;; There's no ambiguity for other symbols or
			 ;; empty lines: stop here.
			 (looking-at "[ \t]*\\(?:[^:#]\\|$\\)")
			 ;; Stop at valid fixed-width areas.
			 (looking-at "[ \t]*:\\(?: \\|$\\)")
			 ;; Stop at drawers.
			 (and (looking-at org-drawer-regexp)
			      (save-excursion
				(re-search-forward
				 "^[ \t]*:END:[ \t]*$" limit t)))
			 ;; Stop at valid comments.
			 (looking-at "[ \t]*#\\(?: \\|$\\)")
			 ;; Stop at valid dynamic blocks.
			 (and (looking-at org-dblock-start-re)
			      (save-excursion
				(re-search-forward
				 "^[ \t]*#\\+END:?[ \t]*$" limit t)))
			 ;; Stop at valid blocks.
			 (and (looking-at "[ \t]*#\\+BEGIN_\\(\\S-+\\)")
			      (save-excursion
				(re-search-forward
				 (format "^[ \t]*#\\+END_%s[ \t]*$"
					 (regexp-quote
					  (org-match-string-no-properties 1)))
				 limit t)))
			 ;; Stop at valid latex environments.
			 (and (looking-at
			       "[ \t]*\\\\begin{\\([A-Za-z0-9]+\\*?\\)}")
			      (save-excursion
				(re-search-forward
				 (format "^[ \t]*\\\\end{%s}[ \t]*$"
					 (regexp-quote
					  (org-match-string-no-properties 1)))
				 limit t)))
			 ;; Stop at valid keywords.
			 (looking-at "[ \t]*#\\+\\S-+:")
			 ;; Skip everything else.
			 (not
			  (progn
			    (end-of-line)
			    (re-search-forward org-element-paragraph-separate
					       limit 'm)))))
		  (beginning-of-line)))
	      (if (= (point) limit) limit
		(goto-char (line-beginning-position)))))
	   (contents-end (progn (skip-chars-backward " \r\t\n" contents-begin)
				(forward-line)
				(point)))
	   (end (progn (skip-chars-forward " \r\t\n" limit)
		       (if (eobp) (point) (line-beginning-position)))))
      (list 'paragraph
	    (nconc
	     (list :begin begin
		   :end end
		   :contents-begin contents-begin
		   :contents-end contents-end
		   :post-blank (count-lines before-blank end)
		   :post-affiliated contents-begin)
	     (cdr affiliated))))))

(defun org-element-paragraph-interpreter (paragraph contents)
  "Interpret PARAGRAPH element as Org syntax.
CONTENTS is the contents of the element."
  contents)


;;;; Planning

(defun org-element-planning-parser (limit)
  "Parse a planning.

LIMIT bounds the search.

Return a list whose CAR is `planning' and CDR is a plist
containing `:closed', `:deadline', `:scheduled', `:begin', `:end'
and `:post-blank' keywords."
  (save-excursion
    (let* ((case-fold-search nil)
	   (begin (point))
	   (post-blank (let ((before-blank (progn (forward-line) (point))))
			 (skip-chars-forward " \r\t\n" limit)
			 (skip-chars-backward " \t")
			 (unless (bolp) (end-of-line))
			 (count-lines before-blank (point))))
	   (end (point))
	   closed deadline scheduled)
      (goto-char begin)
      (while (re-search-forward org-keyword-time-not-clock-regexp end t)
	(goto-char (match-end 1))
	(skip-chars-forward " \t" end)
	(let ((keyword (match-string 1))
	      (time (org-element-timestamp-parser)))
	  (cond ((equal keyword org-closed-string) (setq closed time))
		((equal keyword org-deadline-string) (setq deadline time))
		(t (setq scheduled time)))))
      (list 'planning
	    (list :closed closed
		  :deadline deadline
		  :scheduled scheduled
		  :begin begin
		  :end end
		  :post-blank post-blank)))))

(defun org-element-planning-interpreter (planning contents)
  "Interpret PLANNING element as Org syntax.
CONTENTS is nil."
  (mapconcat
   'identity
   (delq nil
	 (list (let ((deadline (org-element-property :deadline planning)))
		 (when deadline
		   (concat org-deadline-string " "
			   (org-element-timestamp-interpreter deadline nil))))
	       (let ((scheduled (org-element-property :scheduled planning)))
		 (when scheduled
		   (concat org-scheduled-string " "
			   (org-element-timestamp-interpreter scheduled nil))))
	       (let ((closed (org-element-property :closed planning)))
		 (when closed
		   (concat org-closed-string " "
			   (org-element-timestamp-interpreter closed nil))))))
   " "))


;;;; Src Block

(defun org-element-src-block-parser (limit affiliated)
  "Parse a src block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `src-block' and CDR is a plist
containing `:language', `:switches', `:parameters', `:begin',
`:end', `:number-lines', `:retain-labels', `:use-labels',
`:label-fmt', `:preserve-indent', `:value', `:post-blank' and
`:post-affiliated' keywords.

Assume point is at the beginning of the block."
  (let ((case-fold-search t))
    (if (not (save-excursion (re-search-forward "^[ \t]*#\\+END_SRC[ \t]*$"
						limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((contents-end (match-beginning 0)))
	(save-excursion
	  (let* ((begin (car affiliated))
		 (post-affiliated (point))
		 ;; Get language as a string.
		 (language
		  (progn
		    (looking-at
		     (concat "^[ \t]*#\\+BEGIN_SRC"
			     "\\(?: +\\(\\S-+\\)\\)?"
			     "\\(\\(?: +\\(?:-l \".*?\"\\|[-+][A-Za-z]\\)\\)+\\)?"
			     "\\(.*\\)[ \t]*$"))
		    (org-match-string-no-properties 1)))
		 ;; Get switches.
		 (switches (org-match-string-no-properties 2))
		 ;; Get parameters.
		 (parameters (org-match-string-no-properties 3))
		 ;; Switches analysis
		 (number-lines
		  (cond ((not switches) nil)
			((string-match "-n\\>" switches) 'new)
			((string-match "+n\\>" switches) 'continued)))
		 (preserve-indent (and switches
				       (string-match "-i\\>" switches)))
		 (label-fmt
		  (and switches
		       (string-match "-l +\"\\([^\"\n]+\\)\"" switches)
		       (match-string 1 switches)))
		 ;; Should labels be retained in (or stripped from)
		 ;; src blocks?
		 (retain-labels
		  (or (not switches)
		      (not (string-match "-r\\>" switches))
		      (and number-lines (string-match "-k\\>" switches))))
		 ;; What should code-references use - labels or
		 ;; line-numbers?
		 (use-labels
		  (or (not switches)
		      (and retain-labels
			   (not (string-match "-k\\>" switches)))))
		 ;; Indentation.
		 (block-ind (progn (skip-chars-forward " \t") (current-column)))
		 ;; Retrieve code.
		 (value (org-element-remove-indentation
			 (org-unescape-code-in-string
			  (buffer-substring-no-properties
			   (progn (forward-line) (point)) contents-end))
			 block-ind))
		 (pos-before-blank (progn (goto-char contents-end)
					  (forward-line)
					  (point)))
		 ;; Get position after ending blank lines.
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'src-block
		  (nconc
		   (list :language language
			 :switches (and (org-string-nw-p switches)
					(org-trim switches))
			 :parameters (and (org-string-nw-p parameters)
					  (org-trim parameters))
			 :begin begin
			 :end end
			 :number-lines number-lines
			 :preserve-indent preserve-indent
			 :retain-labels retain-labels
			 :use-labels use-labels
			 :label-fmt label-fmt
			 :value value
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-src-block-interpreter (src-block contents)
  "Interpret SRC-BLOCK element as Org syntax.
CONTENTS is nil."
  (let ((lang (org-element-property :language src-block))
	(switches (org-element-property :switches src-block))
	(params (org-element-property :parameters src-block))
	(value
	 (let ((val (org-element-property :value src-block)))
	   (cond
	    ((or org-src-preserve-indentation
		 (org-element-property :preserve-indent src-block))
	     val)
	    ((zerop org-edit-src-content-indentation) val)
	    (t
	     (let ((ind (make-string org-edit-src-content-indentation ?\s)))
	       (replace-regexp-in-string
		"\\(^\\)[ \t]*\\S-" ind val nil nil 1)))))))
    (concat (format "#+BEGIN_SRC%s\n"
		    (concat (and lang (concat " " lang))
			    (and switches (concat " " switches))
			    (and params (concat " " params))))
	    (org-escape-code-in-string value)
	    "#+END_SRC")))


;;;; Table

(defun org-element-table-parser (limit affiliated)
  "Parse a table at point.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `table' and CDR is a plist containing
`:begin', `:end', `:tblfm', `:type', `:contents-begin',
`:contents-end', `:value', `:post-blank' and `:post-affiliated'
keywords.

Assume point is at the beginning of the table."
  (save-excursion
    (let* ((case-fold-search t)
	   (table-begin (point))
	   (type (if (org-at-table.el-p) 'table.el 'org))
	   (begin (car affiliated))
	   (table-end
	    (if (re-search-forward org-table-any-border-regexp limit 'm)
		(goto-char (match-beginning 0))
	      (point)))
	   (tblfm (let (acc)
		    (while (looking-at "[ \t]*#\\+TBLFM: +\\(.*\\)[ \t]*$")
		      (push (org-match-string-no-properties 1) acc)
		      (forward-line))
		    acc))
	   (pos-before-blank (point))
	   (end (progn (skip-chars-forward " \r\t\n" limit)
		       (if (eobp) (point) (line-beginning-position)))))
      (list 'table
	    (nconc
	     (list :begin begin
		   :end end
		   :type type
		   :tblfm tblfm
		   ;; Only `org' tables have contents.  `table.el' tables
		   ;; use a `:value' property to store raw table as
		   ;; a string.
		   :contents-begin (and (eq type 'org) table-begin)
		   :contents-end (and (eq type 'org) table-end)
		   :value (and (eq type 'table.el)
			       (buffer-substring-no-properties
				table-begin table-end))
		   :post-blank (count-lines pos-before-blank end)
		   :post-affiliated table-begin)
	     (cdr affiliated))))))

(defun org-element-table-interpreter (table contents)
  "Interpret TABLE element as Org syntax.
CONTENTS is nil."
  (if (eq (org-element-property :type table) 'table.el)
      (org-remove-indentation (org-element-property :value table))
    (concat (with-temp-buffer (insert contents)
			      (org-table-align)
			      (buffer-string))
	    (mapconcat (lambda (fm) (concat "#+TBLFM: " fm))
		       (reverse (org-element-property :tblfm table))
		       "\n"))))


;;;; Table Row

(defun org-element-table-row-parser (limit)
  "Parse table row at point.

LIMIT bounds the search.

Return a list whose CAR is `table-row' and CDR is a plist
containing `:begin', `:end', `:contents-begin', `:contents-end',
`:type' and `:post-blank' keywords."
  (save-excursion
    (let* ((type (if (looking-at "^[ \t]*|-") 'rule 'standard))
	   (begin (point))
	   ;; A table rule has no contents.  In that case, ensure
	   ;; CONTENTS-BEGIN matches CONTENTS-END.
	   (contents-begin (and (eq type 'standard)
				(search-forward "|")
				(point)))
	   (contents-end (and (eq type 'standard)
			      (progn
				(end-of-line)
				(skip-chars-backward " \t")
				(point))))
	   (end (progn (forward-line) (point))))
      (list 'table-row
	    (list :type type
		  :begin begin
		  :end end
		  :contents-begin contents-begin
		  :contents-end contents-end
		  :post-blank 0)))))

(defun org-element-table-row-interpreter (table-row contents)
  "Interpret TABLE-ROW element as Org syntax.
CONTENTS is the contents of the table row."
  (if (eq (org-element-property :type table-row) 'rule) "|-"
    (concat "| " contents)))


;;;; Verse Block

(defun org-element-verse-block-parser (limit affiliated)
  "Parse a verse block.

LIMIT bounds the search.  AFFILIATED is a list of which CAR is
the buffer position at the beginning of the first affiliated
keyword and CDR is a plist of affiliated keywords along with
their value.

Return a list whose CAR is `verse-block' and CDR is a plist
containing `:begin', `:end', `:contents-begin', `:contents-end',
`:post-blank' and `:post-affiliated' keywords.

Assume point is at beginning of the block."
  (let ((case-fold-search t))
    (if (not (save-excursion
	       (re-search-forward "^[ \t]*#\\+END_VERSE[ \t]*$" limit t)))
	;; Incomplete block: parse it as a paragraph.
	(org-element-paragraph-parser limit affiliated)
      (let ((contents-end (match-beginning 0)))
	(save-excursion
	  (let* ((begin (car affiliated))
		 (post-affiliated (point))
		 (contents-begin (progn (forward-line) (point)))
		 (pos-before-blank (progn (goto-char contents-end)
					  (forward-line)
					  (point)))
		 (end (progn (skip-chars-forward " \r\t\n" limit)
			     (if (eobp) (point) (line-beginning-position)))))
	    (list 'verse-block
		  (nconc
		   (list :begin begin
			 :end end
			 :contents-begin contents-begin
			 :contents-end contents-end
			 :post-blank (count-lines pos-before-blank end)
			 :post-affiliated post-affiliated)
		   (cdr affiliated)))))))))

(defun org-element-verse-block-interpreter (verse-block contents)
  "Interpret VERSE-BLOCK element as Org syntax.
CONTENTS is verse block contents."
  (format "#+BEGIN_VERSE\n%s#+END_VERSE" contents))



;;; Objects
;;
;; Unlike to elements, raw text can be found between objects.  Hence,
;; `org-element--object-lex' is provided to find the next object in
;; buffer.
;;
;; Some object types (e.g., `italic') are recursive.  Restrictions on
;; object types they can contain will be specified in
;; `org-element-object-restrictions'.
;;
;; Creating a new type of object requires to alter
;; `org-element--object-regexp' and `org-element--object-lex', add the
;; new type in `org-element-all-objects', and possibly add
;; restrictions in `org-element-object-restrictions'.

;;;; Bold

(defun org-element-bold-parser ()
  "Parse bold object at point, if any.

When at a bold object, return a list whose car is `bold' and cdr
is a plist with `:begin', `:end', `:contents-begin' and
`:contents-end' and `:post-blank' keywords.  Otherwise, return
nil.

Assume point is at the first star marker."
  (save-excursion
    (unless (bolp) (backward-char 1))
    (when (looking-at org-emph-re)
      (let ((begin (match-beginning 2))
	    (contents-begin (match-beginning 4))
	    (contents-end (match-end 4))
	    (post-blank (progn (goto-char (match-end 2))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'bold
	      (list :begin begin
		    :end end
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-bold-interpreter (bold contents)
  "Interpret BOLD object as Org syntax.
CONTENTS is the contents of the object."
  (format "*%s*" contents))


;;;; Code

(defun org-element-code-parser ()
  "Parse code object at point, if any.

When at a code object, return a list whose car is `code' and cdr
is a plist with `:value', `:begin', `:end' and `:post-blank'
keywords.  Otherwise, return nil.

Assume point is at the first tilde marker."
  (save-excursion
    (unless (bolp) (backward-char 1))
    (when (looking-at org-emph-re)
      (let ((begin (match-beginning 2))
	    (value (org-match-string-no-properties 4))
	    (post-blank (progn (goto-char (match-end 2))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'code
	      (list :value value
		    :begin begin
		    :end end
		    :post-blank post-blank))))))

(defun org-element-code-interpreter (code contents)
  "Interpret CODE object as Org syntax.
CONTENTS is nil."
  (format "~%s~" (org-element-property :value code)))


;;;; Entity

(defun org-element-entity-parser ()
  "Parse entity at point, if any.

When at an entity, return a list whose car is `entity' and cdr
a plist with `:begin', `:end', `:latex', `:latex-math-p',
`:html', `:latin1', `:utf-8', `:ascii', `:use-brackets-p' and
`:post-blank' as keywords.  Otherwise, return nil.

Assume point is at the beginning of the entity."
  (catch 'no-object
    (when (looking-at "\\\\\\(there4\\|sup[123]\\|frac[13][24]\\|[a-zA-Z]+\\)\\($\\|{}\\|[^[:alpha:]]\\)")
      (save-excursion
	(let* ((value (or (org-entity-get (match-string 1))
			  (throw 'no-object nil)))
	       (begin (match-beginning 0))
	       (bracketsp (string= (match-string 2) "{}"))
	       (post-blank (progn (goto-char (match-end 1))
				  (when bracketsp (forward-char 2))
				  (skip-chars-forward " \t")))
	       (end (point)))
	  (list 'entity
		(list :name (car value)
		      :latex (nth 1 value)
		      :latex-math-p (nth 2 value)
		      :html (nth 3 value)
		      :ascii (nth 4 value)
		      :latin1 (nth 5 value)
		      :utf-8 (nth 6 value)
		      :begin begin
		      :end end
		      :use-brackets-p bracketsp
		      :post-blank post-blank)))))))

(defun org-element-entity-interpreter (entity contents)
  "Interpret ENTITY object as Org syntax.
CONTENTS is nil."
  (concat "\\"
	  (org-element-property :name entity)
	  (when (org-element-property :use-brackets-p entity) "{}")))


;;;; Export Snippet

(defun org-element-export-snippet-parser ()
  "Parse export snippet at point.

When at an export snippet, return a list whose car is
`export-snippet' and cdr a plist with `:begin', `:end',
`:back-end', `:value' and `:post-blank' as keywords.  Otherwise,
return nil.

Assume point is at the beginning of the snippet."
  (save-excursion
    (let (contents-end)
      (when (and (looking-at "@@\\([-A-Za-z0-9]+\\):")
		 (setq contents-end
		       (save-match-data (goto-char (match-end 0))
					(re-search-forward "@@" nil t)
					(match-beginning 0))))
	(let* ((begin (match-beginning 0))
	       (back-end (org-match-string-no-properties 1))
	       (value (buffer-substring-no-properties
		       (match-end 0) contents-end))
	       (post-blank (skip-chars-forward " \t"))
	       (end (point)))
	  (list 'export-snippet
		(list :back-end back-end
		      :value value
		      :begin begin
		      :end end
		      :post-blank post-blank)))))))

(defun org-element-export-snippet-interpreter (export-snippet contents)
  "Interpret EXPORT-SNIPPET object as Org syntax.
CONTENTS is nil."
  (format "@@%s:%s@@"
	  (org-element-property :back-end export-snippet)
	  (org-element-property :value export-snippet)))


;;;; Footnote Reference

(defun org-element-footnote-reference-parser ()
  "Parse footnote reference at point, if any.

When at a footnote reference, return a list whose car is
`footnote-reference' and cdr a plist with `:label', `:type',
`:inline-definition', `:begin', `:end' and `:post-blank' as
keywords.  Otherwise, return nil."
  (catch 'no-object
    (when (looking-at org-footnote-re)
      (save-excursion
	(let* ((begin (point))
	       (label (or (org-match-string-no-properties 2)
			  (org-match-string-no-properties 3)
			  (and (match-string 1)
			       (concat "fn:" (org-match-string-no-properties 1)))))
	       (type (if (or (not label) (match-string 1)) 'inline 'standard))
	       (inner-begin (match-end 0))
	       (inner-end
		(let ((count 1))
		  (forward-char)
		  (while (and (> count 0) (re-search-forward "[][]" nil t))
		    (if (equal (match-string 0) "[") (incf count) (decf count)))
		  (unless (zerop count) (throw 'no-object nil))
		  (1- (point))))
	       (post-blank (progn (goto-char (1+ inner-end))
				  (skip-chars-forward " \t")))
	       (end (point))
	       (footnote-reference
		(list 'footnote-reference
		      (list :label label
			    :type type
			    :begin begin
			    :end end
			    :post-blank post-blank))))
	  (org-element-put-property
	   footnote-reference :inline-definition
	   (and (eq type 'inline)
		(org-element-parse-secondary-string
		 (buffer-substring inner-begin inner-end)
		 (org-element-restriction 'footnote-reference)
		 footnote-reference))))))))

(defun org-element-footnote-reference-interpreter (footnote-reference contents)
  "Interpret FOOTNOTE-REFERENCE object as Org syntax.
CONTENTS is nil."
  (let ((label (or (org-element-property :label footnote-reference) "fn:"))
	(def
	 (let ((inline-def
		(org-element-property :inline-definition footnote-reference)))
	   (if (not inline-def) ""
	     (concat ":" (org-element-interpret-data inline-def))))))
    (format "[%s]" (concat label def))))


;;;; Inline Babel Call

(defun org-element-inline-babel-call-parser ()
  "Parse inline babel call at point, if any.

When at an inline babel call, return a list whose car is
`inline-babel-call' and cdr a plist with `:begin', `:end',
`:value' and `:post-blank' as keywords.  Otherwise, return nil.

Assume point is at the beginning of the babel call."
  (save-excursion
    (unless (bolp) (backward-char))
    (when (let ((case-fold-search t))
	    (looking-at org-babel-inline-lob-one-liner-regexp))
      (let ((begin (match-end 1))
	    (value (buffer-substring-no-properties (match-end 1) (match-end 0)))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'inline-babel-call
	      (list :begin begin
		    :end end
		    :value value
		    :post-blank post-blank))))))

(defun org-element-inline-babel-call-interpreter (inline-babel-call contents)
  "Interpret INLINE-BABEL-CALL object as Org syntax.
CONTENTS is nil."
  (org-element-property :value inline-babel-call))


;;;; Inline Src Block

(defun org-element-inline-src-block-parser ()
  "Parse inline source block at point, if any.

When at an inline source block, return a list whose car is
`inline-src-block' and cdr a plist with `:begin', `:end',
`:language', `:value', `:parameters' and `:post-blank' as
keywords.  Otherwise, return nil.

Assume point is at the beginning of the inline src block."
  (save-excursion
    (unless (bolp) (backward-char))
    (when (looking-at org-babel-inline-src-block-regexp)
      (let ((begin (match-beginning 1))
	    (language (org-match-string-no-properties 2))
	    (parameters (org-match-string-no-properties 4))
	    (value (org-match-string-no-properties 5))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'inline-src-block
	      (list :language language
		    :value value
		    :parameters parameters
		    :begin begin
		    :end end
		    :post-blank post-blank))))))

(defun org-element-inline-src-block-interpreter (inline-src-block contents)
  "Interpret INLINE-SRC-BLOCK object as Org syntax.
CONTENTS is nil."
  (let ((language (org-element-property :language inline-src-block))
	(arguments (org-element-property :parameters inline-src-block))
	(body (org-element-property :value inline-src-block)))
    (format "src_%s%s{%s}"
	    language
	    (if arguments (format "[%s]" arguments) "")
	    body)))

;;;; Italic

(defun org-element-italic-parser ()
  "Parse italic object at point, if any.

When at an italic object, return a list whose car is `italic' and
cdr is a plist with `:begin', `:end', `:contents-begin' and
`:contents-end' and `:post-blank' keywords.  Otherwise, return
nil.

Assume point is at the first slash marker."
  (save-excursion
    (unless (bolp) (backward-char 1))
    (when (looking-at org-emph-re)
      (let ((begin (match-beginning 2))
	    (contents-begin (match-beginning 4))
	    (contents-end (match-end 4))
	    (post-blank (progn (goto-char (match-end 2))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'italic
	      (list :begin begin
		    :end end
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-italic-interpreter (italic contents)
  "Interpret ITALIC object as Org syntax.
CONTENTS is the contents of the object."
  (format "/%s/" contents))


;;;; Latex Fragment

(defun org-element-latex-fragment-parser ()
  "Parse LaTeX fragment at point, if any.

When at a LaTeX fragment, return a list whose car is
`latex-fragment' and cdr a plist with `:value', `:begin', `:end',
and `:post-blank' as keywords.  Otherwise, return nil.

Assume point is at the beginning of the LaTeX fragment."
  (catch 'no-object
    (save-excursion
      (let* ((begin (point))
	     (substring-match
	      (or (catch 'exit
		    (dolist (e (cdr org-latex-regexps))
		      (let ((latex-regexp (nth 1 e)))
			(when (or (looking-at latex-regexp)
				  (and (not (bobp))
				       (save-excursion
					 (backward-char)
					 (looking-at latex-regexp))))
			  (throw 'exit (nth 2 e))))))
		  ;; Macro.
		  (and (looking-at "\\\\[a-zA-Z]+\\*?\\(\\(\\[[^][\n{}]*\\]\\)\\|\\({[^{}\n]*}\\)\\)*")
		       0)
		  ;; No fragment found.
		  (throw 'no-object nil)))
	     (value (org-match-string-no-properties substring-match))
	     (post-blank (progn (goto-char (match-end substring-match))
				(skip-chars-forward " \t")))
	     (end (point)))
	(list 'latex-fragment
	      (list :value value
		    :begin begin
		    :end end
		    :post-blank post-blank))))))

(defun org-element-latex-fragment-interpreter (latex-fragment contents)
  "Interpret LATEX-FRAGMENT object as Org syntax.
CONTENTS is nil."
  (org-element-property :value latex-fragment))

;;;; Line Break

(defun org-element-line-break-parser ()
  "Parse line break at point, if any.

When at a line break, return a list whose car is `line-break',
and cdr a plist with `:begin', `:end' and `:post-blank' keywords.
Otherwise, return nil.

Assume point is at the beginning of the line break."
  (when (and (org-looking-at-p "\\\\\\\\[ \t]*$")
	     (not (eq (char-before) ?\\)))
    (list 'line-break
	  (list :begin (point)
		:end (progn (forward-line) (point))
		:post-blank 0))))

(defun org-element-line-break-interpreter (line-break contents)
  "Interpret LINE-BREAK object as Org syntax.
CONTENTS is nil."
  "\\\\\n")


;;;; Link

(defun org-element-link-parser ()
  "Parse link at point, if any.

When at a link, return a list whose car is `link' and cdr a plist
with `:type', `:path', `:raw-link', `:application',
`:search-option', `:begin', `:end', `:contents-begin',
`:contents-end' and `:post-blank' as keywords.  Otherwise, return
nil.

Assume point is at the beginning of the link."
  (catch 'no-object
    (let ((begin (point))
	  end contents-begin contents-end link-end post-blank path type
	  raw-link link search-option application)
      (cond
       ;; Type 1: Text targeted from a radio target.
       ((and org-target-link-regexp
	     (save-excursion (or (bolp) (backward-char))
			     (looking-at org-target-link-regexp)))
	(setq type "radio"
	      link-end (match-end 1)
	      path (org-match-string-no-properties 1)
	      contents-begin (match-beginning 1)
	      contents-end (match-end 1)))
       ;; Type 2: Standard link, i.e. [[http://orgmode.org][homepage]]
       ((looking-at org-bracket-link-regexp)
	(setq contents-begin (match-beginning 3)
	      contents-end (match-end 3)
	      link-end (match-end 0)
	      ;; RAW-LINK is the original link.  Expand any
	      ;; abbreviation in it.
	      raw-link (org-translate-link
			(org-link-expand-abbrev
			 (org-match-string-no-properties 1))))
	;; Determine TYPE of link and set PATH accordingly.
	(cond
	 ;; File type.
	 ((or (file-name-absolute-p raw-link)
	      (string-match "^\\.\\.?/" raw-link))
	  (setq type "file" path raw-link))
	 ;; Explicit type (http, irc, bbdb...).  See `org-link-types'.
	 ((string-match org-link-re-with-space3 raw-link)
	  (setq type (match-string 1 raw-link) path (match-string 2 raw-link)))
	 ;; Id type: PATH is the id.
	 ((string-match "^id:\\([-a-f0-9]+\\)" raw-link)
	  (setq type "id" path (match-string 1 raw-link)))
	 ;; Code-ref type: PATH is the name of the reference.
	 ((string-match "^(\\(.*\\))$" raw-link)
	  (setq type "coderef" path (match-string 1 raw-link)))
	 ;; Custom-id type: PATH is the name of the custom id.
	 ((= (aref raw-link 0) ?#)
	  (setq type "custom-id" path (substring raw-link 1)))
	 ;; Fuzzy type: Internal link either matches a target, an
	 ;; headline name or nothing.  PATH is the target or
	 ;; headline's name.
	 (t (setq type "fuzzy" path raw-link))))
       ;; Type 3: Plain link, e.g., http://orgmode.org
       ((looking-at org-plain-link-re)
	(setq raw-link (org-match-string-no-properties 0)
	      type (org-match-string-no-properties 1)
	      link-end (match-end 0)
	      path (org-match-string-no-properties 2)))
       ;; Type 4: Angular link, e.g., <http://orgmode.org>
       ((looking-at org-angle-link-re)
	(setq raw-link (buffer-substring-no-properties
			(match-beginning 1) (match-end 2))
	      type (org-match-string-no-properties 1)
	      link-end (match-end 0)
	      path (org-match-string-no-properties 2)))
       (t (throw 'no-object nil)))
      ;; In any case, deduce end point after trailing white space from
      ;; LINK-END variable.
      (save-excursion
	(setq post-blank (progn (goto-char link-end) (skip-chars-forward " \t"))
	      end (point))
	;; Special "file" type link processing.
	(when (member type org-element-link-type-is-file)
	  ;; Extract opening application and search option.
	  (cond ((string-match "^file\\+\\(.*\\)$" type)
		 (setq application (match-string 1 type)))
		((not (string-match "^file" type))
		 (setq application type)))
	  (when (string-match "::\\(.*\\)\\'" path)
	    (setq search-option (match-string 1 path)
		  path (replace-match "" nil nil path)))
	  ;; Normalize URI.
	  (when (and (not (org-string-match-p "\\`//" path))
		     (file-name-absolute-p path))
	    (setq path (concat "//" (expand-file-name path))))
	  ;; Make sure TYPE always reports "file".
	  (setq type "file"))
	(list 'link
	      (list :type type
		    :path path
		    :raw-link (or raw-link path)
		    :application application
		    :search-option search-option
		    :begin begin
		    :end end
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-link-interpreter (link contents)
  "Interpret LINK object as Org syntax.
CONTENTS is the contents of the object, or nil."
  (let ((type (org-element-property :type link))
	(raw-link (org-element-property :raw-link link)))
    (if (string= type "radio") raw-link
      (format "[[%s]%s]"
	      raw-link
	      (if contents (format "[%s]" contents) "")))))


;;;; Macro

(defun org-element-macro-parser ()
  "Parse macro at point, if any.

When at a macro, return a list whose car is `macro' and cdr
a plist with `:key', `:args', `:begin', `:end', `:value' and
`:post-blank' as keywords.  Otherwise, return nil.

Assume point is at the macro."
  (save-excursion
    (when (looking-at "{{{\\([a-zA-Z][-a-zA-Z0-9_]*\\)\\(([ \t\n]*\\([^\000]*?\\))\\)?}}}")
      (let ((begin (point))
	    (key (downcase (org-match-string-no-properties 1)))
	    (value (org-match-string-no-properties 0))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point))
	    (args (let ((args (org-match-string-no-properties 3)))
		    (when args
		      ;; Do not use `org-split-string' since empty
		      ;; strings are meaningful here.
		      (split-string
		       (replace-regexp-in-string
			"\\(\\\\*\\)\\(,\\)"
			(lambda (str)
			  (let ((len (length (match-string 1 str))))
			    (concat (make-string (/ len 2) ?\\)
				    (if (zerop (mod len 2)) "\000" ","))))
			args nil t)
		       "\000")))))
	(list 'macro
	      (list :key key
		    :value value
		    :args args
		    :begin begin
		    :end end
		    :post-blank post-blank))))))

(defun org-element-macro-interpreter (macro contents)
  "Interpret MACRO object as Org syntax.
CONTENTS is nil."
  (org-element-property :value macro))


;;;; Radio-target

(defun org-element-radio-target-parser ()
  "Parse radio target at point, if any.

When at a radio target, return a list whose car is `radio-target'
and cdr a plist with `:begin', `:end', `:contents-begin',
`:contents-end', `:value' and `:post-blank' as keywords.
Otherwise, return nil.

Assume point is at the radio target."
  (save-excursion
    (when (looking-at org-radio-target-regexp)
      (let ((begin (point))
	    (contents-begin (match-beginning 1))
	    (contents-end (match-end 1))
	    (value (org-match-string-no-properties 1))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'radio-target
	      (list :begin begin
		    :end end
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank
		    :value value))))))

(defun org-element-radio-target-interpreter (target contents)
  "Interpret TARGET object as Org syntax.
CONTENTS is the contents of the object."
  (concat "<<<" contents ">>>"))


;;;; Statistics Cookie

(defun org-element-statistics-cookie-parser ()
  "Parse statistics cookie at point, if any.

When at a statistics cookie, return a list whose car is
`statistics-cookie', and cdr a plist with `:begin', `:end',
`:value' and `:post-blank' keywords.  Otherwise, return nil.

Assume point is at the beginning of the statistics-cookie."
  (save-excursion
    (when (looking-at "\\[[0-9]*\\(%\\|/[0-9]*\\)\\]")
      (let* ((begin (point))
	     (value (buffer-substring-no-properties
		     (match-beginning 0) (match-end 0)))
	     (post-blank (progn (goto-char (match-end 0))
				(skip-chars-forward " \t")))
	     (end (point)))
	(list 'statistics-cookie
	      (list :begin begin
		    :end end
		    :value value
		    :post-blank post-blank))))))

(defun org-element-statistics-cookie-interpreter (statistics-cookie contents)
  "Interpret STATISTICS-COOKIE object as Org syntax.
CONTENTS is nil."
  (org-element-property :value statistics-cookie))


;;;; Strike-Through

(defun org-element-strike-through-parser ()
  "Parse strike-through object at point, if any.

When at a strike-through object, return a list whose car is
`strike-through' and cdr is a plist with `:begin', `:end',
`:contents-begin' and `:contents-end' and `:post-blank' keywords.
Otherwise, return nil.

Assume point is at the first plus sign marker."
  (save-excursion
    (unless (bolp) (backward-char 1))
    (when (looking-at org-emph-re)
      (let ((begin (match-beginning 2))
	    (contents-begin (match-beginning 4))
	    (contents-end (match-end 4))
	    (post-blank (progn (goto-char (match-end 2))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'strike-through
	      (list :begin begin
		    :end end
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-strike-through-interpreter (strike-through contents)
  "Interpret STRIKE-THROUGH object as Org syntax.
CONTENTS is the contents of the object."
  (format "+%s+" contents))


;;;; Subscript

(defun org-element-subscript-parser ()
  "Parse subscript at point, if any.

When at a subscript object, return a list whose car is
`subscript' and cdr a plist with `:begin', `:end',
`:contents-begin', `:contents-end', `:use-brackets-p' and
`:post-blank' as keywords.  Otherwise, return nil.

Assume point is at the underscore."
  (save-excursion
    (unless (bolp) (backward-char))
    (when (looking-at org-match-substring-regexp)
      (let ((bracketsp (match-beginning 4))
	    (begin (match-beginning 2))
	    (contents-begin (or (match-beginning 4)
				(match-beginning 3)))
	    (contents-end (or (match-end 4) (match-end 3)))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'subscript
	      (list :begin begin
		    :end end
		    :use-brackets-p bracketsp
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-subscript-interpreter (subscript contents)
  "Interpret SUBSCRIPT object as Org syntax.
CONTENTS is the contents of the object."
  (format
   (if (org-element-property :use-brackets-p subscript) "_{%s}" "_%s")
   contents))


;;;; Superscript

(defun org-element-superscript-parser ()
  "Parse superscript at point, if any.

When at a superscript object, return a list whose car is
`superscript' and cdr a plist with `:begin', `:end',
`:contents-begin', `:contents-end', `:use-brackets-p' and
`:post-blank' as keywords.  Otherwise, return nil.

Assume point is at the caret."
  (save-excursion
    (unless (bolp) (backward-char))
    (when (looking-at org-match-substring-regexp)
      (let ((bracketsp (match-beginning 4))
	    (begin (match-beginning 2))
	    (contents-begin (or (match-beginning 4)
				(match-beginning 3)))
	    (contents-end (or (match-end 4) (match-end 3)))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'superscript
	      (list :begin begin
		    :end end
		    :use-brackets-p bracketsp
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-superscript-interpreter (superscript contents)
  "Interpret SUPERSCRIPT object as Org syntax.
CONTENTS is the contents of the object."
  (format
   (if (org-element-property :use-brackets-p superscript) "^{%s}" "^%s")
   contents))


;;;; Table Cell

(defun org-element-table-cell-parser ()
  "Parse table cell at point.
Return a list whose car is `table-cell' and cdr is a plist
containing `:begin', `:end', `:contents-begin', `:contents-end'
and `:post-blank' keywords."
  (looking-at "[ \t]*\\(.*?\\)[ \t]*\\(?:|\\|$\\)")
  (let* ((begin (match-beginning 0))
	 (end (match-end 0))
	 (contents-begin (match-beginning 1))
	 (contents-end (match-end 1)))
    (list 'table-cell
	  (list :begin begin
		:end end
		:contents-begin contents-begin
		:contents-end contents-end
		:post-blank 0))))

(defun org-element-table-cell-interpreter (table-cell contents)
  "Interpret TABLE-CELL element as Org syntax.
CONTENTS is the contents of the cell, or nil."
  (concat  " " contents " |"))


;;;; Target

(defun org-element-target-parser ()
  "Parse target at point, if any.

When at a target, return a list whose car is `target' and cdr
a plist with `:begin', `:end', `:value' and `:post-blank' as
keywords.  Otherwise, return nil.

Assume point is at the target."
  (save-excursion
    (when (looking-at org-target-regexp)
      (let ((begin (point))
	    (value (org-match-string-no-properties 1))
	    (post-blank (progn (goto-char (match-end 0))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'target
	      (list :begin begin
		    :end end
		    :value value
		    :post-blank post-blank))))))

(defun org-element-target-interpreter (target contents)
  "Interpret TARGET object as Org syntax.
CONTENTS is nil."
  (format "<<%s>>" (org-element-property :value target)))


;;;; Timestamp

(defconst org-element--timestamp-regexp
  (concat org-ts-regexp-both
	  "\\|"
	  "\\(?:<[0-9]+-[0-9]+-[0-9]+[^>\n]+?\\+[0-9]+[dwmy]>\\)"
	  "\\|"
	  "\\(?:<%%\\(?:([^>\n]+)\\)>\\)")
  "Regexp matching any timestamp type object.")

(defun org-element-timestamp-parser ()
  "Parse time stamp at point, if any.

When at a time stamp, return a list whose car is `timestamp', and
cdr a plist with `:type', `:raw-value', `:year-start',
`:month-start', `:day-start', `:hour-start', `:minute-start',
`:year-end', `:month-end', `:day-end', `:hour-end',
`:minute-end', `:repeater-type', `:repeater-value',
`:repeater-unit', `:warning-type', `:warning-value',
`:warning-unit', `:begin', `:end' and `:post-blank' keywords.
Otherwise, return nil.

Assume point is at the beginning of the timestamp."
  (when (org-looking-at-p org-element--timestamp-regexp)
    (save-excursion
      (let* ((begin (point))
	     (activep (eq (char-after) ?<))
	     (raw-value
	      (progn
		(looking-at "\\([<[]\\(%%\\)?.*?\\)[]>]\\(?:--\\([<[].*?[]>]\\)\\)?")
		(match-string-no-properties 0)))
	     (date-start (match-string-no-properties 1))
	     (date-end (match-string 3))
	     (diaryp (match-beginning 2))
	     (post-blank (progn (goto-char (match-end 0))
				(skip-chars-forward " \t")))
	     (end (point))
	     (time-range
	      (and (not diaryp)
		   (string-match
		    "[012]?[0-9]:[0-5][0-9]\\(-\\([012]?[0-9]\\):\\([0-5][0-9]\\)\\)"
		    date-start)
		   (cons (string-to-number (match-string 2 date-start))
			 (string-to-number (match-string 3 date-start)))))
	     (type (cond (diaryp 'diary)
			 ((and activep (or date-end time-range)) 'active-range)
			 (activep 'active)
			 ((or date-end time-range) 'inactive-range)
			 (t 'inactive)))
	     (repeater-props
	      (and (not diaryp)
		   (string-match "\\([.+]?\\+\\)\\([0-9]+\\)\\([hdwmy]\\)"
				 raw-value)
		   (list
		    :repeater-type
		    (let ((type (match-string 1 raw-value)))
		      (cond ((equal "++" type) 'catch-up)
			    ((equal ".+" type) 'restart)
			    (t 'cumulate)))
		    :repeater-value (string-to-number (match-string 2 raw-value))
		    :repeater-unit
		    (case (string-to-char (match-string 3 raw-value))
		      (?h 'hour) (?d 'day) (?w 'week) (?m 'month) (t 'year)))))
	     (warning-props
	      (and (not diaryp)
		   (string-match "\\(-\\)?-\\([0-9]+\\)\\([hdwmy]\\)" raw-value)
		   (list
		    :warning-type (if (match-string 1 raw-value) 'first 'all)
		    :warning-value (string-to-number (match-string 2 raw-value))
		    :warning-unit
		    (case (string-to-char (match-string 3 raw-value))
		      (?h 'hour) (?d 'day) (?w 'week) (?m 'month) (t 'year)))))
	     year-start month-start day-start hour-start minute-start year-end
	     month-end day-end hour-end minute-end)
	;; Parse date-start.
	(unless diaryp
	  (let ((date (org-parse-time-string date-start t)))
	    (setq year-start (nth 5 date)
		  month-start (nth 4 date)
		  day-start (nth 3 date)
		  hour-start (nth 2 date)
		  minute-start (nth 1 date))))
	;; Compute date-end.  It can be provided directly in time-stamp,
	;; or extracted from time range.  Otherwise, it defaults to the
	;; same values as date-start.
	(unless diaryp
	  (let ((date (and date-end (org-parse-time-string date-end t))))
	    (setq year-end (or (nth 5 date) year-start)
		  month-end (or (nth 4 date) month-start)
		  day-end (or (nth 3 date) day-start)
		  hour-end (or (nth 2 date) (car time-range) hour-start)
		  minute-end (or (nth 1 date) (cdr time-range) minute-start))))
	(list 'timestamp
	      (nconc (list :type type
			   :raw-value raw-value
			   :year-start year-start
			   :month-start month-start
			   :day-start day-start
			   :hour-start hour-start
			   :minute-start minute-start
			   :year-end year-end
			   :month-end month-end
			   :day-end day-end
			   :hour-end hour-end
			   :minute-end minute-end
			   :begin begin
			   :end end
			   :post-blank post-blank)
		     repeater-props
		     warning-props))))))

(defun org-element-timestamp-interpreter (timestamp contents)
  "Interpret TIMESTAMP object as Org syntax.
CONTENTS is nil."
  (let* ((repeat-string
	  (concat
	   (case (org-element-property :repeater-type timestamp)
	     (cumulate "+") (catch-up "++") (restart ".+"))
	   (let ((val (org-element-property :repeater-value timestamp)))
	     (and val (number-to-string val)))
	   (case (org-element-property :repeater-unit timestamp)
	     (hour "h") (day "d") (week "w") (month "m") (year "y"))))
	 (warning-string
	  (concat
	   (case (org-element-property :warning-type timestamp)
	     (first "--")
	     (all "-"))
	   (let ((val (org-element-property :warning-value timestamp)))
	     (and val (number-to-string val)))
	   (case (org-element-property :warning-unit timestamp)
	     (hour "h") (day "d") (week "w") (month "m") (year "y"))))
	 (build-ts-string
	  ;; Build an Org timestamp string from TIME.  ACTIVEP is
	  ;; non-nil when time stamp is active.  If WITH-TIME-P is
	  ;; non-nil, add a time part.  HOUR-END and MINUTE-END
	  ;; specify a time range in the timestamp.  REPEAT-STRING is
	  ;; the repeater string, if any.
	  (lambda (time activep &optional with-time-p hour-end minute-end)
	    (let ((ts (format-time-string
		       (funcall (if with-time-p 'cdr 'car)
				org-time-stamp-formats)
		       time)))
	      (when (and hour-end minute-end)
		(string-match "[012]?[0-9]:[0-5][0-9]" ts)
		(setq ts
		      (replace-match
		       (format "\\&-%02d:%02d" hour-end minute-end)
		       nil nil ts)))
	      (unless activep (setq ts (format "[%s]" (substring ts 1 -1))))
	      (dolist (s (list repeat-string warning-string))
		(when (org-string-nw-p s)
		  (setq ts (concat (substring ts 0 -1)
				   " "
				   s
				   (substring ts -1)))))
	      ;; Return value.
	      ts)))
	 (type (org-element-property :type timestamp)))
    (case type
      ((active inactive)
       (let* ((minute-start (org-element-property :minute-start timestamp))
	      (minute-end (org-element-property :minute-end timestamp))
	      (hour-start (org-element-property :hour-start timestamp))
	      (hour-end (org-element-property :hour-end timestamp))
	      (time-range-p (and hour-start hour-end minute-start minute-end
				 (or (/= hour-start hour-end)
				     (/= minute-start minute-end)))))
	 (funcall
	  build-ts-string
	  (encode-time 0
		       (or minute-start 0)
		       (or hour-start 0)
		       (org-element-property :day-start timestamp)
		       (org-element-property :month-start timestamp)
		       (org-element-property :year-start timestamp))
	  (eq type 'active)
	  (and hour-start minute-start)
	  (and time-range-p hour-end)
	  (and time-range-p minute-end))))
      ((active-range inactive-range)
       (let ((minute-start (org-element-property :minute-start timestamp))
	     (minute-end (org-element-property :minute-end timestamp))
	     (hour-start (org-element-property :hour-start timestamp))
	     (hour-end (org-element-property :hour-end timestamp)))
	 (concat
	  (funcall
	   build-ts-string (encode-time
			    0
			    (or minute-start 0)
			    (or hour-start 0)
			    (org-element-property :day-start timestamp)
			    (org-element-property :month-start timestamp)
			    (org-element-property :year-start timestamp))
	   (eq type 'active-range)
	   (and hour-start minute-start))
	  "--"
	  (funcall build-ts-string
		   (encode-time 0
				(or minute-end 0)
				(or hour-end 0)
				(org-element-property :day-end timestamp)
				(org-element-property :month-end timestamp)
				(org-element-property :year-end timestamp))
		   (eq type 'active-range)
		   (and hour-end minute-end))))))))


;;;; Underline

(defun org-element-underline-parser ()
  "Parse underline object at point, if any.

When at an underline object, return a list whose car is
`underline' and cdr is a plist with `:begin', `:end',
`:contents-begin' and `:contents-end' and `:post-blank' keywords.
Otherwise, return nil.

Assume point is at the first underscore marker."
  (save-excursion
    (unless (bolp) (backward-char 1))
    (when (looking-at org-emph-re)
      (let ((begin (match-beginning 2))
	    (contents-begin (match-beginning 4))
	    (contents-end (match-end 4))
	    (post-blank (progn (goto-char (match-end 2))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'underline
	      (list :begin begin
		    :end end
		    :contents-begin contents-begin
		    :contents-end contents-end
		    :post-blank post-blank))))))

(defun org-element-underline-interpreter (underline contents)
  "Interpret UNDERLINE object as Org syntax.
CONTENTS is the contents of the object."
  (format "_%s_" contents))


;;;; Verbatim

(defun org-element-verbatim-parser ()
  "Parse verbatim object at point, if any.

When at a verbatim object, return a list whose car is `verbatim'
and cdr is a plist with `:value', `:begin', `:end' and
`:post-blank' keywords.  Otherwise, return nil.

Assume point is at the first equal sign marker."
  (save-excursion
    (unless (bolp) (backward-char 1))
    (when (looking-at org-emph-re)
      (let ((begin (match-beginning 2))
	    (value (org-match-string-no-properties 4))
	    (post-blank (progn (goto-char (match-end 2))
			       (skip-chars-forward " \t")))
	    (end (point)))
	(list 'verbatim
	      (list :value value
		    :begin begin
		    :end end
		    :post-blank post-blank))))))

(defun org-element-verbatim-interpreter (verbatim contents)
  "Interpret VERBATIM object as Org syntax.
CONTENTS is nil."
  (format "=%s=" (org-element-property :value verbatim)))



;;; Parsing Element Starting At Point
;;
;; `org-element--current-element' is the core function of this section.
;; It returns the Lisp representation of the element starting at
;; point.
;;
;; `org-element--current-element' makes use of special modes.  They
;; are activated for fixed element chaining (e.g., `plain-list' >
;; `item') or fixed conditional element chaining (e.g., `headline' >
;; `section').  Special modes are: `first-section', `item',
;; `node-property', `section' and `table-row'.

(defun org-element--current-element
  (limit &optional granularity special structure)
  "Parse the element starting at point.

Return value is a list like (TYPE PROPS) where TYPE is the type
of the element and PROPS a plist of properties associated to the
element.

Possible types are defined in `org-element-all-elements'.

LIMIT bounds the search.

Optional argument GRANULARITY determines the depth of the
recursion.  Allowed values are `headline', `greater-element',
`element', `object' or nil.  When it is broader than `object' (or
nil), secondary values will not be parsed, since they only
contain objects.

Optional argument SPECIAL, when non-nil, can be either
`first-section', `item', `node-property', `section', and
`table-row'.

If STRUCTURE isn't provided but SPECIAL is set to `item', it will
be computed.

This function assumes point is always at the beginning of the
element it has to parse."
  (save-excursion
    (let ((case-fold-search t)
	  ;; Determine if parsing depth allows for secondary strings
	  ;; parsing.  It only applies to elements referenced in
	  ;; `org-element-secondary-value-alist'.
	  (raw-secondary-p (and granularity (not (eq granularity 'object)))))
      (cond
       ;; Item.
       ((eq special 'item)
	(org-element-item-parser limit structure raw-secondary-p))
       ;; Table Row.
       ((eq special 'table-row) (org-element-table-row-parser limit))
       ;; Node Property.
       ((eq special 'node-property) (org-element-node-property-parser limit))
       ;; Headline.
       ((org-with-limited-levels (org-at-heading-p))
        (org-element-headline-parser limit raw-secondary-p))
       ;; Sections (must be checked after headline).
       ((eq special 'section) (org-element-section-parser limit))
       ((eq special 'first-section)
	(org-element-section-parser
	 (or (save-excursion (org-with-limited-levels (outline-next-heading)))
	     limit)))
       ;; When not at bol, point is at the beginning of an item or
       ;; a footnote definition: next item is always a paragraph.
       ((not (bolp)) (org-element-paragraph-parser limit (list (point))))
       ;; Planning and Clock.
       ((looking-at org-planning-or-clock-line-re)
	(if (equal (match-string 1) org-clock-string)
	    (org-element-clock-parser limit)
	  (org-element-planning-parser limit)))
       ;; Inlinetask.
       ((org-at-heading-p)
	(org-element-inlinetask-parser limit raw-secondary-p))
       ;; From there, elements can have affiliated keywords.
       (t (let ((affiliated (org-element--collect-affiliated-keywords limit)))
	    (cond
	     ;; Jumping over affiliated keywords put point off-limits.
	     ;; Parse them as regular keywords.
	     ((and (cdr affiliated) (>= (point) limit))
	      (goto-char (car affiliated))
	      (org-element-keyword-parser limit nil))
	     ;; LaTeX Environment.
	     ((looking-at
	       "[ \t]*\\\\begin{[A-Za-z0-9*]+}\\(\\[.*?\\]\\|{.*?}\\)*[ \t]*$")
	      (org-element-latex-environment-parser limit affiliated))
	     ;; Drawer and Property Drawer.
	     ((looking-at org-drawer-regexp)
	      (if (equal (match-string 1) "PROPERTIES")
		  (org-element-property-drawer-parser limit affiliated)
		(org-element-drawer-parser limit affiliated)))
	     ;; Fixed Width
	     ((looking-at "[ \t]*:\\( \\|$\\)")
	      (org-element-fixed-width-parser limit affiliated))
	     ;; Inline Comments, Blocks, Babel Calls, Dynamic Blocks and
	     ;; Keywords.
	     ((looking-at "[ \t]*#")
	      (goto-char (match-end 0))
	      (cond ((looking-at "\\(?: \\|$\\)")
		     (beginning-of-line)
		     (org-element-comment-parser limit affiliated))
		    ((looking-at "\\+BEGIN_\\(\\S-+\\)")
		     (beginning-of-line)
		     (let ((parser (assoc (upcase (match-string 1))
					  org-element-block-name-alist)))
		       (if parser (funcall (cdr parser) limit affiliated)
			 (org-element-special-block-parser limit affiliated))))
		    ((looking-at "\\+CALL:")
		     (beginning-of-line)
		     (org-element-babel-call-parser limit affiliated))
		    ((looking-at "\\+BEGIN:? ")
		     (beginning-of-line)
		     (org-element-dynamic-block-parser limit affiliated))
		    ((looking-at "\\+\\S-+:")
		     (beginning-of-line)
		     (org-element-keyword-parser limit affiliated))
		    (t
		     (beginning-of-line)
		     (org-element-paragraph-parser limit affiliated))))
	     ;; Footnote Definition.
	     ((looking-at org-footnote-definition-re)
	      (org-element-footnote-definition-parser limit affiliated))
	     ;; Horizontal Rule.
	     ((looking-at "[ \t]*-\\{5,\\}[ \t]*$")
	      (org-element-horizontal-rule-parser limit affiliated))
	     ;; Diary Sexp.
	     ((looking-at "%%(")
	      (org-element-diary-sexp-parser limit affiliated))
	     ;; Table.
	     ((org-at-table-p t) (org-element-table-parser limit affiliated))
	     ;; List.
	     ((looking-at (org-item-re))
	      (org-element-plain-list-parser
	       limit affiliated
	       (or structure (org-element--list-struct limit))))
	     ;; Default element: Paragraph.
	     (t (org-element-paragraph-parser limit affiliated)))))))))


;; Most elements can have affiliated keywords.  When looking for an
;; element beginning, we want to move before them, as they belong to
;; that element, and, in the meantime, collect information they give
;; into appropriate properties.  Hence the following function.

(defun org-element--collect-affiliated-keywords (limit)
  "Collect affiliated keywords from point down to LIMIT.

Return a list whose CAR is the position at the first of them and
CDR a plist of keywords and values and move point to the
beginning of the first line after them.

As a special case, if element doesn't start at the beginning of
the line (e.g., a paragraph starting an item), CAR is current
position of point and CDR is nil."
  (if (not (bolp)) (list (point))
    (let ((case-fold-search t)
	  (origin (point))
	  ;; RESTRICT is the list of objects allowed in parsed
	  ;; keywords value.
	  (restrict (org-element-restriction 'keyword))
	  output)
      (while (and (< (point) limit) (looking-at org-element--affiliated-re))
	(let* ((raw-kwd (upcase (match-string 1)))
	       ;; Apply translation to RAW-KWD.  From there, KWD is
	       ;; the official keyword.
	       (kwd (or (cdr (assoc raw-kwd
				    org-element-keyword-translation-alist))
			raw-kwd))
	       ;; Find main value for any keyword.
	       (value
		(save-match-data
		  (org-trim
		   (buffer-substring-no-properties
		    (match-end 0) (point-at-eol)))))
	       ;; PARSEDP is non-nil when keyword should have its
	       ;; value parsed.
	       (parsedp (member kwd org-element-parsed-keywords))
	       ;; If KWD is a dual keyword, find its secondary
	       ;; value.  Maybe parse it.
	       (dualp (member kwd org-element-dual-keywords))
	       (dual-value
		(and dualp
		     (let ((sec (org-match-string-no-properties 2)))
		       (if (or (not sec) (not parsedp)) sec
			 (org-element-parse-secondary-string sec restrict)))))
	       ;; Attribute a property name to KWD.
	       (kwd-sym (and kwd (intern (concat ":" (downcase kwd))))))
	  ;; Now set final shape for VALUE.
	  (when parsedp
	    (setq value (org-element-parse-secondary-string value restrict)))
	  (when dualp
	    (setq value (and (or value dual-value) (cons value dual-value))))
	  (when (or (member kwd org-element-multiple-keywords)
		    ;; Attributes can always appear on multiple lines.
		    (string-match "^ATTR_" kwd))
	    (setq value (cons value (plist-get output kwd-sym))))
	  ;; Eventually store the new value in OUTPUT.
	  (setq output (plist-put output kwd-sym value))
	  ;; Move to next keyword.
	  (forward-line)))
      ;; If affiliated keywords are orphaned: move back to first one.
      ;; They will be parsed as a paragraph.
      (when (looking-at "[ \t]*$") (goto-char origin) (setq output nil))
      ;; Return value.
      (cons origin output))))



;;; The Org Parser
;;
;; The two major functions here are `org-element-parse-buffer', which
;; parses Org syntax inside the current buffer, taking into account
;; region, narrowing, or even visibility if specified, and
;; `org-element-parse-secondary-string', which parses objects within
;; a given string.
;;
;; The (almost) almighty `org-element-map' allows to apply a function
;; on elements or objects matching some type, and accumulate the
;; resulting values.  In an export situation, it also skips unneeded
;; parts of the parse tree.

(defun org-element-parse-buffer (&optional granularity visible-only)
  "Recursively parse the buffer and return structure.
If narrowing is in effect, only parse the visible part of the
buffer.

Optional argument GRANULARITY determines the depth of the
recursion.  It can be set to the following symbols:

`headline'          Only parse headlines.
`greater-element'   Don't recurse into greater elements excepted
		    headlines and sections.  Thus, elements
		    parsed are the top-level ones.
`element'           Parse everything but objects and plain text.
`object'            Parse the complete buffer (default).

When VISIBLE-ONLY is non-nil, don't parse contents of hidden
elements.

An element or an objects is represented as a list with the
pattern (TYPE PROPERTIES CONTENTS), where :

  TYPE is a symbol describing the element or object.  See
  `org-element-all-elements' and `org-element-all-objects' for an
  exhaustive list of such symbols.  One can retrieve it with
  `org-element-type' function.

  PROPERTIES is the list of attributes attached to the element or
  object, as a plist.  Although most of them are specific to the
  element or object type, all types share `:begin', `:end',
  `:post-blank' and `:parent' properties, which respectively
  refer to buffer position where the element or object starts,
  ends, the number of white spaces or blank lines after it, and
  the element or object containing it.  Properties values can be
  obtained by using `org-element-property' function.

  CONTENTS is a list of elements, objects or raw strings
  contained in the current element or object, when applicable.
  One can access them with `org-element-contents' function.

The Org buffer has `org-data' as type and nil as properties.
`org-element-map' function can be used to find specific elements
or objects within the parse tree.

This function assumes that current major mode is `org-mode'."
  (save-excursion
    (goto-char (point-min))
    (org-skip-whitespace)
    (org-element--parse-elements
     (point-at-bol) (point-max)
     ;; Start in `first-section' mode so text before the first
     ;; headline belongs to a section.
     'first-section nil granularity visible-only (list 'org-data nil))))

(defun org-element-parse-secondary-string (string restriction &optional parent)
  "Recursively parse objects in STRING and return structure.

RESTRICTION is a symbol limiting the object types that will be
looked after.

Optional argument PARENT, when non-nil, is the element or object
containing the secondary string.  It is used to set correctly
`:parent' property within the string."
  ;; Copy buffer-local variables listed in
  ;; `org-element-object-variables' into temporary buffer.  This is
  ;; required since object parsing is dependent on these variables.
  (let ((pairs (delq nil (mapcar (lambda (var)
				   (when (boundp var)
				     (cons var (symbol-value var))))
				 org-element-object-variables))))
    (with-temp-buffer
      (mapc (lambda (pair) (org-set-local (car pair) (cdr pair))) pairs)
      (insert string)
      (let ((secondary (org-element--parse-objects
			(point-min) (point-max) nil restriction)))
	(when parent
	  (mapc (lambda (obj) (org-element-put-property obj :parent parent))
		secondary))
	secondary))))

(defun org-element-map
  (data types fun &optional info first-match no-recursion with-affiliated)
  "Map a function on selected elements or objects.

DATA is a parse tree, an element, an object, a string, or a list
of such constructs.  TYPES is a symbol or list of symbols of
elements or objects types (see `org-element-all-elements' and
`org-element-all-objects' for a complete list of types).  FUN is
the function called on the matching element or object.  It has to
accept one argument: the element or object itself.

When optional argument INFO is non-nil, it should be a plist
holding export options.  In that case, parts of the parse tree
not exportable according to that property list will be skipped.

When optional argument FIRST-MATCH is non-nil, stop at the first
match for which FUN doesn't return nil, and return that value.

Optional argument NO-RECURSION is a symbol or a list of symbols
representing elements or objects types.  `org-element-map' won't
enter any recursive element or object whose type belongs to that
list.  Though, FUN can still be applied on them.

When optional argument WITH-AFFILIATED is non-nil, FUN will also
apply to matching objects within parsed affiliated keywords (see
`org-element-parsed-keywords').

Nil values returned from FUN do not appear in the results.


Examples:
---------

Assuming TREE is a variable containing an Org buffer parse tree,
the following example will return a flat list of all `src-block'
and `example-block' elements in it:

  \(org-element-map tree '(example-block src-block) 'identity)

The following snippet will find the first headline with a level
of 1 and a \"phone\" tag, and will return its beginning position:

  \(org-element-map tree 'headline
   \(lambda (hl)
     \(and (= (org-element-property :level hl) 1)
          \(member \"phone\" (org-element-property :tags hl))
          \(org-element-property :begin hl)))
   nil t)

The next example will return a flat list of all `plain-list' type
elements in TREE that are not a sub-list themselves:

  \(org-element-map tree 'plain-list 'identity nil nil 'plain-list)

Eventually, this example will return a flat list of all `bold'
type objects containing a `latex-snippet' type object, even
looking into captions:

  \(org-element-map tree 'bold
   \(lambda (b)
     \(and (org-element-map b 'latex-snippet 'identity nil t) b))
   nil nil nil t)"
  ;; Ensure TYPES and NO-RECURSION are a list, even of one element.
  (unless (listp types) (setq types (list types)))
  (unless (listp no-recursion) (setq no-recursion (list no-recursion)))
  ;; Recursion depth is determined by --CATEGORY.
  (let* ((--category
	  (catch 'found
	    (let ((category 'greater-elements))
	      (mapc (lambda (type)
		      (cond ((or (memq type org-element-all-objects)
				 (eq type 'plain-text))
			     ;; If one object is found, the function
			     ;; has to recurse into every object.
			     (throw 'found 'objects))
			    ((not (memq type org-element-greater-elements))
			     ;; If one regular element is found, the
			     ;; function has to recurse, at least,
			     ;; into every element it encounters.
			     (and (not (eq category 'elements))
				  (setq category 'elements)))))
		    types)
	      category)))
	 ;; Compute properties for affiliated keywords if necessary.
	 (--affiliated-alist
	  (and with-affiliated
	       (mapcar (lambda (kwd)
			 (cons kwd (intern (concat ":" (downcase kwd)))))
		       org-element-affiliated-keywords)))
	 --acc
	 --walk-tree
	 (--walk-tree
	  (function
	   (lambda (--data)
	     ;; Recursively walk DATA.  INFO, if non-nil, is a plist
	     ;; holding contextual information.
	     (let ((--type (org-element-type --data)))
	       (cond
		((not --data))
		;; Ignored element in an export context.
		((and info (memq --data (plist-get info :ignore-list))))
		;; List of elements or objects.
		((not --type) (mapc --walk-tree --data))
		;; Unconditionally enter parse trees.
		((eq --type 'org-data)
		 (mapc --walk-tree (org-element-contents --data)))
		(t
		 ;; Check if TYPE is matching among TYPES.  If so,
		 ;; apply FUN to --DATA and accumulate return value
		 ;; into --ACC (or exit if FIRST-MATCH is non-nil).
		 (when (memq --type types)
		   (let ((result (funcall fun --data)))
		     (cond ((not result))
			   (first-match (throw '--map-first-match result))
			   (t (push result --acc)))))
		 ;; If --DATA has a secondary string that can contain
		 ;; objects with their type among TYPES, look into it.
		 (when (and (eq --category 'objects) (not (stringp --data)))
		   (let ((sec-prop
			  (assq --type org-element-secondary-value-alist)))
		     (when sec-prop
		       (funcall --walk-tree
				(org-element-property (cdr sec-prop) --data)))))
		 ;; If --DATA has any affiliated keywords and
		 ;; WITH-AFFILIATED is non-nil, look for objects in
		 ;; them.
		 (when (and with-affiliated
			    (eq --category 'objects)
			    (memq --type org-element-all-elements))
		   (mapc (lambda (kwd-pair)
			   (let ((kwd (car kwd-pair))
				 (value (org-element-property
					 (cdr kwd-pair) --data)))
			     ;; Pay attention to the type of value.
			     ;; Preserve order for multiple keywords.
			     (cond
			      ((not value))
			      ((and (member kwd org-element-multiple-keywords)
				    (member kwd org-element-dual-keywords))
			       (mapc (lambda (line)
				       (funcall --walk-tree (cdr line))
				       (funcall --walk-tree (car line)))
				     (reverse value)))
			      ((member kwd org-element-multiple-keywords)
			       (mapc (lambda (line) (funcall --walk-tree line))
				     (reverse value)))
			      ((member kwd org-element-dual-keywords)
			       (funcall --walk-tree (cdr value))
			       (funcall --walk-tree (car value)))
			      (t (funcall --walk-tree value)))))
			 --affiliated-alist))
		 ;; Determine if a recursion into --DATA is possible.
		 (cond
		  ;; --TYPE is explicitly removed from recursion.
		  ((memq --type no-recursion))
		  ;; --DATA has no contents.
		  ((not (org-element-contents --data)))
		  ;; Looking for greater elements but --DATA is simply
		  ;; an element or an object.
		  ((and (eq --category 'greater-elements)
			(not (memq --type org-element-greater-elements))))
		  ;; Looking for elements but --DATA is an object.
		  ((and (eq --category 'elements)
			(memq --type org-element-all-objects)))
		  ;; In any other case, map contents.
		  (t (mapc --walk-tree (org-element-contents --data)))))))))))
    (catch '--map-first-match
      (funcall --walk-tree data)
      ;; Return value in a proper order.
      (nreverse --acc))))
(put 'org-element-map 'lisp-indent-function 2)

;; The following functions are internal parts of the parser.
;;
;; The first one, `org-element--parse-elements' acts at the element's
;; level.
;;
;; The second one, `org-element--parse-objects' applies on all objects
;; of a paragraph or a secondary string.
;;
;; More precisely, that function looks for every allowed object type
;; first.  Then, it discards failed searches, keeps further matches,
;; and searches again types matched behind point, for subsequent
;; calls.  Thus, searching for a given type fails only once, and every
;; object is searched only once at top level (but sometimes more for
;; nested types).

(defun org-element--parse-elements
  (beg end special structure granularity visible-only acc)
  "Parse elements between BEG and END positions.

SPECIAL prioritize some elements over the others.  It can be set
to `first-section', `section' `item' or `table-row'.

When value is `item', STRUCTURE will be used as the current list
structure.

GRANULARITY determines the depth of the recursion.  See
`org-element-parse-buffer' for more information.

When VISIBLE-ONLY is non-nil, don't parse contents of hidden
elements.

Elements are accumulated into ACC."
  (save-excursion
    (goto-char beg)
    ;; Visible only: skip invisible parts at the beginning of the
    ;; element.
    (when (and visible-only (org-invisible-p2))
      (goto-char (min (1+ (org-find-visible)) end)))
    ;; When parsing only headlines, skip any text before first one.
    (when (and (eq granularity 'headline) (not (org-at-heading-p)))
      (org-with-limited-levels (outline-next-heading)))
    ;; Main loop start.
    (while (< (point) end)
      ;; Find current element's type and parse it accordingly to
      ;; its category.
      (let* ((element (org-element--current-element
		       end granularity special structure))
	     (type (org-element-type element))
	     (cbeg (org-element-property :contents-begin element)))
	(goto-char (org-element-property :end element))
	;; Visible only: skip invisible parts between siblings.
	(when (and visible-only (org-invisible-p2))
	  (goto-char (min (1+ (org-find-visible)) end)))
	;; Fill ELEMENT contents by side-effect.
	(cond
	 ;; If element has no contents, don't modify it.
	 ((not cbeg))
	 ;; Greater element: parse it between `contents-begin' and
	 ;; `contents-end'.  Make sure GRANULARITY allows the
	 ;; recursion, or ELEMENT is a headline, in which case going
	 ;; inside is mandatory, in order to get sub-level headings.
	 ((and (memq type org-element-greater-elements)
	       (or (memq granularity '(element object nil))
		   (and (eq granularity 'greater-element)
			(eq type 'section))
		   (eq type 'headline)))
	  (org-element--parse-elements
	   cbeg (org-element-property :contents-end element)
	   ;; Possibly switch to a special mode.
	   (case type
	     (headline 'section)
	     (plain-list 'item)
	     (property-drawer 'node-property)
	     (table 'table-row))
	   (and (memq type '(item plain-list))
		(org-element-property :structure element))
	   granularity visible-only element))
	 ;; ELEMENT has contents.  Parse objects inside, if
	 ;; GRANULARITY allows it.
	 ((memq granularity '(object nil))
	  (org-element--parse-objects
	   cbeg (org-element-property :contents-end element) element
	   (org-element-restriction type))))
	(org-element-adopt-elements acc element)))
    ;; Return result.
    acc))

(defconst org-element--object-regexp
  (mapconcat #'identity
	     (let ((link-types (regexp-opt org-link-types)))
	       (list
		;; Sub/superscript.
		"\\(?:[_^][-{(*+.,[:alnum:]]\\)"
		;; Bold, code, italic, strike-through, underline and
		;; verbatim.
		(concat "[*~=+_/]"
			(format "[^%s]" (nth 2 org-emphasis-regexp-components)))
		;; Plain links.
		(concat "\\<" link-types ":")
		;; Objects starting with "[": regular link, footnote
		;; reference, statistics cookie, timestamp (inactive).
		"\\[\\(?:fn:\\|\\(?:[0-9]\\|\\(?:%\\|/[0-9]*\\)\\]\\)\\|\\[\\)"
		;; Objects starting with "@": export snippets.
		"@@"
		;; Objects starting with "{": macro.
		"{{{"
		;; Objects starting with "<" : timestamp (active,
		;; diary), target, radio target and angular links.
		(concat "<\\(?:%%\\|<\\|[0-9]\\|" link-types "\\)")
		;; Objects starting with "$": latex fragment.
		"\\$"
		;; Objects starting with "\": line break, entity,
		;; latex fragment.
		"\\\\\\(?:[a-zA-Z[(]\\|\\\\[ \t]*$\\)"
		;; Objects starting with raw text: inline Babel
		;; source block, inline Babel call.
		"\\(?:call\\|src\\)_"))
	     "\\|")
  "Regexp possibly matching the beginning of an object.
This regexp allows false positives.  Dedicated parser (e.g.,
`org-export-bold-parser') will take care of further filtering.
Radio links are not matched by this regexp, as they are treated
specially in `org-element--object-lex'.")

(defun org-element--object-lex (restriction)
  "Return next object in current buffer or nil.
RESTRICTION is a list of object types, as symbols, that should be
looked after.  This function assumes that the buffer is narrowed
to an appropriate container (e.g., a paragraph)."
  (if (memq 'table-cell restriction) (org-element-table-cell-parser)
    (save-excursion
      (let ((limit (and org-target-link-regexp
			(save-excursion
			  (or (bolp) (backward-char))
			  (re-search-forward org-target-link-regexp nil t))
			(match-beginning 1)))
	    found)
	(while (and (not found)
		    (re-search-forward org-element--object-regexp limit t))
	  (goto-char (match-beginning 0))
	  (let ((result (match-string 0)))
	    (setq found
		  (cond
		   ((eq (compare-strings result nil nil "call_" nil nil t) t)
		    (and (memq 'inline-babel-call restriction)
			 (org-element-inline-babel-call-parser)))
		   ((eq (compare-strings result nil nil "src_" nil nil t) t)
		    (and (memq 'inline-src-block restriction)
			 (org-element-inline-src-block-parser)))
		   (t
		    (case (char-after)
		      (?^ (and (memq 'superscript restriction)
			       (org-element-superscript-parser)))
		      (?_ (or (and (memq 'subscript restriction)
				   (org-element-subscript-parser))
			      (and (memq 'underline restriction)
				   (org-element-underline-parser))))
		      (?* (and (memq 'bold restriction)
			       (org-element-bold-parser)))
		      (?/ (and (memq 'italic restriction)
			       (org-element-italic-parser)))
		      (?~ (and (memq 'code restriction)
			       (org-element-code-parser)))
		      (?= (and (memq 'verbatim restriction)
			       (org-element-verbatim-parser)))
		      (?+ (and (memq 'strike-through restriction)
			       (org-element-strike-through-parser)))
		      (?@ (and (memq 'export-snippet restriction)
			       (org-element-export-snippet-parser)))
		      (?{ (and (memq 'macro restriction)
			       (org-element-macro-parser)))
		      (?$ (and (memq 'latex-fragment restriction)
			       (org-element-latex-fragment-parser)))
		      (?<
		       (if (eq (aref result 1) ?<)
			   (or (and (memq 'radio-target restriction)
				    (org-element-radio-target-parser))
			       (and (memq 'target restriction)
				    (org-element-target-parser)))
			 (or (and (memq 'timestamp restriction)
				  (org-element-timestamp-parser))
			     (and (memq 'link restriction)
				  (org-element-link-parser)))))
		      (?\\ (or (and (memq 'line-break restriction)
				    (org-element-line-break-parser))
			       (and (memq 'entity restriction)
				    (org-element-entity-parser))
			       (and (memq 'latex-fragment restriction)
				    (org-element-latex-fragment-parser))))
		      (?\[
		       (if (eq (aref result 1) ?\[)
			   (and (memq 'link restriction)
				(org-element-link-parser))
			 (or (and (memq 'footnote-reference restriction)
				  (org-element-footnote-reference-parser))
			     (and (memq 'timestamp restriction)
				  (org-element-timestamp-parser))
			     (and (memq 'statistics-cookie restriction)
				  (org-element-statistics-cookie-parser)))))
		      ;; This is probably a plain link.
		      (otherwise (and (or (memq 'link restriction)
					  (memq 'plain-link restriction))
				      (org-element-link-parser)))))))
	    (or (eobp) (forward-char))))
	(cond (found)
	      ;; Radio link.
	      ((and limit (memq 'link restriction))
	       (goto-char limit) (org-element-link-parser)))))))

(defun org-element--parse-objects (beg end acc restriction)
  "Parse objects between BEG and END and return recursive structure.

Objects are accumulated in ACC.

RESTRICTION is a list of object successors which are allowed in
the current object."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (let (next-object)
	(while (and (not (eobp))
		    (setq next-object (org-element--object-lex restriction)))
	  ;; 1. Text before any object.  Untabify it.
	  (let ((obj-beg (org-element-property :begin next-object)))
	    (unless (= (point) obj-beg)
	      (setq acc
		    (org-element-adopt-elements
		     acc
		     (replace-regexp-in-string
		      "\t" (make-string tab-width ? )
		      (buffer-substring-no-properties (point) obj-beg))))))
	  ;; 2. Object...
	  (let ((obj-end (org-element-property :end next-object))
		(cont-beg (org-element-property :contents-begin next-object)))
	    ;; Fill contents of NEXT-OBJECT by side-effect, if it has
	    ;; a recursive type.
	    (when (and cont-beg
		       (memq (car next-object) org-element-recursive-objects))
	      (org-element--parse-objects
	       cont-beg (org-element-property :contents-end next-object)
	       next-object (org-element-restriction next-object)))
	    (setq acc (org-element-adopt-elements acc next-object))
	    (goto-char obj-end))))
      ;; 3. Text after last object.  Untabify it.
      (unless (eobp)
	(setq acc
	      (org-element-adopt-elements
	       acc
	       (replace-regexp-in-string
		"\t" (make-string tab-width ? )
		(buffer-substring-no-properties (point) end)))))
      ;; Result.
      acc)))



;;; Towards A Bijective Process
;;
;; The parse tree obtained with `org-element-parse-buffer' is really
;; a snapshot of the corresponding Org buffer.  Therefore, it can be
;; interpreted and expanded into a string with canonical Org syntax.
;; Hence `org-element-interpret-data'.
;;
;; The function relies internally on
;; `org-element--interpret-affiliated-keywords'.

;;;###autoload
(defun org-element-interpret-data (data &optional pseudo-objects)
  "Interpret DATA as Org syntax.

DATA is a parse tree, an element, an object or a secondary string
to interpret.

Optional argument PSEUDO-OBJECTS is a list of symbols defining
new types that should be treated as objects.  An unknown type not
belonging to this list is seen as a pseudo-element instead.  Both
pseudo-objects and pseudo-elements are transparent entities, i.e.
only their contents are interpreted.

Return Org syntax as a string."
  (org-element--interpret-data-1 data nil pseudo-objects))

(defun org-element--interpret-data-1 (data parent pseudo-objects)
  "Interpret DATA as Org syntax.

DATA is a parse tree, an element, an object or a secondary string
to interpret.  PARENT is used for recursive calls.  It contains
the element or object containing data, or nil.  PSEUDO-OBJECTS
are list of symbols defining new element or object types.
Unknown types that don't belong to this list are treated as
pseudo-elements instead.

Return Org syntax as a string."
  (let* ((type (org-element-type data))
	 ;; Find interpreter for current object or element.  If it
	 ;; doesn't exist (e.g. this is a pseudo object or element),
	 ;; return contents, if any.
	 (interpret
	  (let ((fun (intern (format "org-element-%s-interpreter" type))))
	    (if (fboundp fun) fun (lambda (data contents) contents))))
	 (results
	  (cond
	   ;; Secondary string.
	   ((not type)
	    (mapconcat
	     (lambda (obj)
	       (org-element--interpret-data-1 obj parent pseudo-objects))
	     data ""))
	   ;; Full Org document.
	   ((eq type 'org-data)
	    (mapconcat
	     (lambda (obj)
	       (org-element--interpret-data-1 obj parent pseudo-objects))
	     (org-element-contents data) ""))
	   ;; Plain text: return it.
	   ((stringp data) data)
	   ;; Element or object without contents.
	   ((not (org-element-contents data)) (funcall interpret data nil))
	   ;; Element or object with contents.
	   (t
	    (funcall interpret data
		     ;; Recursively interpret contents.
		     (mapconcat
		      (lambda (obj)
			(org-element--interpret-data-1 obj data pseudo-objects))
		      (org-element-contents
		       (if (not (memq type '(paragraph verse-block)))
			   data
			 ;; Fix indentation of elements containing
			 ;; objects.  We ignore `table-row' elements
			 ;; as they are one line long anyway.
			 (org-element-normalize-contents
			  data
			  ;; When normalizing first paragraph of an
			  ;; item or a footnote-definition, ignore
			  ;; first line's indentation.
			  (and (eq type 'paragraph)
			       (equal data (car (org-element-contents parent)))
			       (memq (org-element-type parent)
				     '(footnote-definition item))))))
		      ""))))))
    (if (memq type '(org-data plain-text nil)) results
      ;; Build white spaces.  If no `:post-blank' property is
      ;; specified, assume its value is 0.
      (let ((post-blank (or (org-element-property :post-blank data) 0)))
	(if (or (memq type org-element-all-objects)
		(memq type pseudo-objects))
	    (concat results (make-string post-blank ?\s))
	  (concat
	   (org-element--interpret-affiliated-keywords data)
	   (org-element-normalize-string results)
	   (make-string post-blank ?\n)))))))

(defun org-element--interpret-affiliated-keywords (element)
  "Return ELEMENT's affiliated keywords as Org syntax.
If there is no affiliated keyword, return the empty string."
  (let ((keyword-to-org
	 (function
	  (lambda (key value)
	    (let (dual)
	      (when (member key org-element-dual-keywords)
		(setq dual (cdr value) value (car value)))
	      (concat "#+" key
		      (and dual
			   (format "[%s]" (org-element-interpret-data dual)))
		      ": "
		      (if (member key org-element-parsed-keywords)
			  (org-element-interpret-data value)
			value)
		      "\n"))))))
    (mapconcat
     (lambda (prop)
       (let ((value (org-element-property prop element))
	     (keyword (upcase (substring (symbol-name prop) 1))))
	 (when value
	   (if (or (member keyword org-element-multiple-keywords)
		   ;; All attribute keywords can have multiple lines.
		   (string-match "^ATTR_" keyword))
	       (mapconcat (lambda (line) (funcall keyword-to-org keyword line))
			  (reverse value)
			  "")
	     (funcall keyword-to-org keyword value)))))
     ;; List all ELEMENT's properties matching an attribute line or an
     ;; affiliated keyword, but ignore translated keywords since they
     ;; cannot belong to the property list.
     (loop for prop in (nth 1 element) by 'cddr
	   when (let ((keyword (upcase (substring (symbol-name prop) 1))))
		  (or (string-match "^ATTR_" keyword)
		      (and
		       (member keyword org-element-affiliated-keywords)
		       (not (assoc keyword
				   org-element-keyword-translation-alist)))))
	   collect prop)
     "")))

;; Because interpretation of the parse tree must return the same
;; number of blank lines between elements and the same number of white
;; space after objects, some special care must be given to white
;; spaces.
;;
;; The first function, `org-element-normalize-string', ensures any
;; string different from the empty string will end with a single
;; newline character.
;;
;; The second function, `org-element-normalize-contents', removes
;; global indentation from the contents of the current element.

(defun org-element-normalize-string (s)
  "Ensure string S ends with a single newline character.

If S isn't a string return it unchanged.  If S is the empty
string, return it.  Otherwise, return a new string with a single
newline character at its end."
  (cond
   ((not (stringp s)) s)
   ((string= "" s) "")
   (t (and (string-match "\\(\n[ \t]*\\)*\\'" s)
	   (replace-match "\n" nil nil s)))))

(defun org-element-normalize-contents (element &optional ignore-first)
  "Normalize plain text in ELEMENT's contents.

ELEMENT must only contain plain text and objects.

If optional argument IGNORE-FIRST is non-nil, ignore first line's
indentation to compute maximal common indentation.

Return the normalized element that is element with global
indentation removed from its contents.  The function assumes that
indentation is not done with TAB characters."
  (let* ((min-ind most-positive-fixnum)
	 find-min-ind			; For byte-compiler.
	 (find-min-ind
	  (function
	   ;; Return minimal common indentation within BLOB.  This is
	   ;; done by walking recursively BLOB and updating MIN-IND
	   ;; along the way.  FIRST-FLAG is non-nil when the first
	   ;; string hasn't been seen yet.  It is required as this
	   ;; string is the only one whose indentation doesn't happen
	   ;; after a newline character.
	   (lambda (blob first-flag)
	     (dolist (object (org-element-contents blob))
	       (when (and first-flag (stringp object))
		 (setq first-flag nil)
		 (string-match "\\`\\( *\\)" object)
		 (let ((len (length (match-string 1 object))))
		   ;; An indentation of zero means no string will be
		   ;; modified.  Quit the process.
		   (if (zerop len) (throw 'zero (setq min-ind 0))
		     (setq min-ind (min len min-ind)))))
	       (cond
		((stringp object)
		 (dolist (line (delq "" (cdr (org-split-string object " *\n"))))
		   (setq min-ind (min (org-get-indentation line) min-ind))))
		((memq (org-element-type object) org-element-recursive-objects)
		 (funcall find-min-ind object first-flag))))))))
    ;; Find minimal indentation in ELEMENT.
    (catch 'zero (funcall find-min-ind element (not ignore-first)))
    (if (or (zerop min-ind) (= min-ind most-positive-fixnum)) element
      ;; Build ELEMENT back, replacing each string with the same
      ;; string minus common indentation.
      (let* (build			; For byte compiler.
	     (build
	      (function
	       (lambda (blob first-flag)
		 ;; Return BLOB with all its strings indentation
		 ;; shortened from MIN-IND white spaces.  FIRST-FLAG
		 ;; is non-nil when the first string hasn't been seen
		 ;; yet.
		 (setcdr (cdr blob)
			 (mapcar
			  #'(lambda (object)
			      (when (and first-flag (stringp object))
				(setq first-flag nil)
				(setq object
				      (replace-regexp-in-string
				       (format "\\` \\{%d\\}" min-ind)
				       "" object)))
			      (cond
			       ((stringp object)
				(replace-regexp-in-string
				 (format "\n \\{%d\\}" min-ind) "\n" object))
			       ((memq (org-element-type object)
				      org-element-recursive-objects)
				(funcall build object first-flag))
			       (t object)))
			  (org-element-contents blob)))
		 blob))))
	(funcall build element (not ignore-first))))))



;;; Cache
;;
;; Implement a caching mechanism for `org-element-at-point' and
;; `org-element-context', which see.
;;
;; A single public function is provided: `org-element-cache-reset'.
;;
;; Cache is enabled by default, but can be disabled globally with
;; `org-element-use-cache'.  `org-element-cache-sync-idle-time',
;; org-element-cache-sync-duration' and `org-element-cache-sync-break'
;; can be tweaked to control caching behaviour.
;;
;; Internally, parsed elements are stored in an AVL tree,
;; `org-element--cache'.  This tree is updated lazily: whenever
;; a change happens to the buffer, a synchronization request is
;; registered in `org-element--cache-sync-requests' (see
;; `org-element--cache-submit-request').  During idle time, requests
;; are processed by `org-element--cache-sync'.  Synchronization also
;; happens when an element is required from the cache.  In this case,
;; the process stops as soon as the needed element is up-to-date.
;;
;; A synchronization request can only apply on a synchronized part of
;; the cache.  Therefore, the cache is updated at least to the
;; location where the new request applies.  Thus, requests are ordered
;; from left to right and all elements starting before the first
;; request are correct.  This property is used by functions like
;; `org-element--cache-find' to retrieve elements in the part of the
;; cache that can be trusted.
;;
;; A request applies to every element, starting from its original
;; location (or key, see below).  When a request is processed, it
;; moves forward and may collide the next one.  In this case, both
;; requests are merged into a new one that starts from that element.
;; As a consequence, the whole synchronization complexity does not
;; depend on the number of pending requests, but on the number of
;; elements the very first request will be applied on.
;;
;; Elements cannot be accessed through their beginning position, which
;; may or may not be up-to-date.  Instead, each element in the tree is
;; associated to a key, obtained with `org-element--cache-key'.  This
;; mechanism is robust enough to preserve total order among elements
;; even when the tree is only partially synchronized.
;;
;; Objects contained in an element are stored in a hash table,
;; `org-element--cache-objects'.


(defvar org-element-use-cache t
  "Non nil when Org parser should cache its results.
This is mostly for debugging purpose.")

(defvar org-element-cache-sync-idle-time 0.4
  "Length, in seconds, of idle time before syncing cache.")

(defvar org-element-cache-sync-duration (seconds-to-time 0.04)
  "Maximum duration, as a time value, for a cache synchronization.
If the synchronization is not over after this delay, the process
pauses and resumes after `org-element-cache-sync-break'
seconds.")

(defvar org-element-cache-sync-break (seconds-to-time 0.2)
  "Duration, as a time value, of the pause between synchronizations.
See `org-element-cache-sync-duration' for more information.")


;;;; Data Structure

(defvar org-element--cache nil
  "AVL tree used to cache elements.
Each node of the tree contains an element.  Comparison is done
with `org-element--cache-compare'.  This cache is used in
`org-element-at-point'.")

(defvar org-element--cache-objects nil
  "Hash table used as to cache objects.
Key is an element, as returned by `org-element-at-point', and
value is an alist where each association is:

  \(PARENT COMPLETEP . OBJECTS)

where PARENT is an element or object, COMPLETEP is a boolean,
non-nil when all direct children of parent are already cached and
OBJECTS is a list of such children, as objects, from farthest to
closest.

In the following example, \\alpha, bold object and \\beta are
contained within a paragraph

  \\alpha *\\beta*

If the paragraph is completely parsed, OBJECTS-DATA will be

  \((PARAGRAPH t BOLD-OBJECT ENTITY-OBJECT)
   \(BOLD-OBJECT t ENTITY-OBJECT))

whereas in a partially parsed paragraph, it could be

  \((PARAGRAPH nil ENTITY-OBJECT))

This cache is used in `org-element-context'.")

(defvar org-element--cache-sync-requests nil
  "List of pending synchronization requests.

A request is a vector with the following pattern:

 \[NEXT END OFFSET PARENT PHASE]

Processing a synchronization request consists in three phases:

  0. Delete modified elements,
  1. Fill missing area in cache,
  2. Shift positions and re-parent elements after the changes.

During phase 0, NEXT is the key of the first element to be
removed and END is buffer position delimiting the modifications.
Every element starting between these are removed.  PARENT is an
element to be removed.  Every element contained in it will also
be removed.

During phase 1, NEXT is the key of the next known element in
cache.  Parse buffer between that element and the one before it
in order to determine the parent of the next element.  Set PARENT
to the element containing NEXT.

During phase 2, NEXT is the key of the next element to shift in
the parse tree.  All elements starting from this one have their
properties relatives to buffer positions shifted by integer
OFFSET and, if they belong to element PARENT, are adopted by it.

PHASE specifies the phase number, as an integer.")

(defvar org-element--cache-sync-timer nil
  "Timer used for cache synchronization.")

(defvar org-element--cache-sync-keys nil
  "Hash table used to store keys during synchronization.
See `org-element--cache-key' for more information.")

(defsubst org-element--cache-key (element)
  "Return a unique key for ELEMENT in cache tree.

Keys are used to keep a total order among elements in the cache.
Comparison is done with `org-element--cache-key-less-p'.

When no synchronization is taking place, a key is simply the
beginning position of the element, or that position plus one in
the case of an first item (respectively row) in
a list (respectively a table).

During a synchronization, the key is the one the element had when
the cache was synchronized for the last time.  Elements added to
cache during the synchronization get a new key generated with
`org-element--cache-generate-key'.

Such keys are stored in `org-element--cache-sync-keys'.  The hash
table is cleared once the synchronization is complete."
  (or (gethash element org-element--cache-sync-keys)
      (let* ((begin (org-element-property :begin element))
	     ;; Increase beginning position of items (respectively
	     ;; table rows) by one, so the first item can get
	     ;; a different key from its parent list (respectively
	     ;; table).
	     (key (if (memq (org-element-type element) '(item table-row))
		      (1+ begin)
		    begin)))
	(if org-element--cache-sync-requests
	    (puthash element key org-element--cache-sync-keys)
	  key))))

(defconst org-element--cache-default-key (ash most-positive-fixnum -1)
  "Default value for a new key level.
See `org-element--cache-generate-key' for more information.")

(defun org-element--cache-generate-key (lower upper)
  "Generate a key between LOWER and UPPER.

LOWER and UPPER are integers or lists, possibly empty.

If LOWER and UPPER are equals, return LOWER.  Otherwise, return
a unique key, as an integer or a list of integers, according to
the following rules:

  - LOWER and UPPER are compared level-wise until values differ.

  - If, at a given level, LOWER and UPPER differ from more than
    2, the new key shares all the levels above with LOWER and
    gets a new level.  Its value is the mean between LOWER and
    UPPER.

      \(1 2) + (1 4) --> (1 3)

  - If LOWER has no value to compare with, it is assumed that its
    value is 0:

      \(1 1) + (1 1 2) --> (1 1 1)

    Likewise, if UPPER is short of levels, the current value is
    `most-positive-fixnum'.

  - If they differ from only one, the new key inherits from
    current LOWER lever and has a new level at the value
    `org-element--cache-default-key'.

      \(1 2) + (1 3) --> (1 2 org-element--cache-default-key)

  - If the key is only one level long, it is returned as an
    integer.

      \(1 2) + (3 2) --> 2"
  (if (equal lower upper) lower
    (let ((lower (if (integerp lower) (list lower) lower))
	  (upper (if (integerp upper) (list upper) upper))
	  key)
      (catch 'exit
	(while (and lower upper)
	  (let ((lower-level (car lower))
		(upper-level (car upper)))
	    (cond
	     ((= lower-level upper-level)
	      (push lower-level key)
	      (setq lower (cdr lower) upper (cdr upper)))
	     ((= (- upper-level lower-level) 1)
	      (push lower-level key)
	      (setq lower (cdr lower))
	      (while (and lower (= (car lower) most-positive-fixnum))
		(push most-positive-fixnum key)
		(setq lower (cdr lower)))
	      (push (if lower
			(let ((n (car lower)))
			  (+ (ash (if (zerop (mod n 2)) n (1+ n)) -1)
			     org-element--cache-default-key))
		      org-element--cache-default-key)
		    key)
	      (throw 'exit t))
	     (t
	      (push (let ((n (car lower)))
		      (+ (ash (if (zerop (mod n 2)) n (1+ n)) -1)
			 (ash (car upper) -1)))
		    key)
	      (throw 'exit t)))))
	(cond
	 ((not lower)
	  (while (and upper (zerop (car upper)))
	    (push 0 key)
	    (setq upper (cdr upper)))
	  ;; (n) is equivalent to (n 0 0 0 0 ...) so we want to avoid
	  ;; ending on a sequence of 0.
	  (if (= (car upper) 1)
	      (progn (push 0 key)
		     (push org-element--cache-default-key key))
	    (push (if upper (ash (car upper) -1) org-element--cache-default-key)
		  key)))
	 ((not upper)
	  (while (and lower (= (car lower) most-positive-fixnum))
	    (push most-positive-fixnum key)
	    (setq lower (cdr lower)))
	  (push (if lower
		    (let ((n (car lower)))
		      (+ (ash (if (zerop (mod n 2)) n (1+ n)) -1)
			 org-element--cache-default-key))
		  org-element--cache-default-key)
		key))))
      ;; Ensure we don't return a list with a single element.
      (if (cdr key) (nreverse key) (car key)))))

(defsubst org-element--cache-key-less-p (a b)
  "Non-nil if key A is less than key B.
A and B are either integers or lists of integers, as returned by
`org-element--cache-key'."
  (if (integerp a) (if (integerp b) (< a b) (<= a (car b)))
    (if (integerp b) (< (car a) b)
      (catch 'exit
	(while (and a b)
	  (cond ((car-less-than-car a b) (throw 'exit t))
		((car-less-than-car b a) (throw 'exit nil))
		(t (setq a (cdr a) b (cdr b)))))
	;; If A is empty, either keys are equal (B is also empty) or
	;; B is less than A (B is longer).  Therefore return nil.
	;;
	;; If A is not empty, B is necessarily empty and A is less
	;; than B (A is longer).  Therefore, return a non-nil value.
	a))))

(defun org-element--cache-compare (a b)
  "Non-nil when element A is located before element B."
  (org-element--cache-key-less-p (org-element--cache-key a)
				 (org-element--cache-key b)))

(defsubst org-element--cache-root ()
  "Return root value in cache.
This function assumes `org-element--cache' is a valid AVL tree."
  (avl-tree--node-left (avl-tree--dummyroot org-element--cache)))


;;;; Tools

(defsubst org-element--cache-active-p ()
  "Non-nil when cache is active in current buffer."
  (and org-element-use-cache
       (or (derived-mode-p 'org-mode) orgstruct-mode)))

(defun org-element--cache-find (pos &optional side)
  "Find element in cache starting at POS or before.

POS refers to a buffer position.

When optional argument SIDE is non-nil, the function checks for
elements starting at or past POS instead.  If SIDE is `both', the
function returns a cons cell where car is the first element
starting at or before POS and cdr the first element starting
after POS.

The function can only find elements in the synchronized part of
the cache."
  (let ((limit (and org-element--cache-sync-requests
		    (aref (car org-element--cache-sync-requests) 0)))
	(node (org-element--cache-root))
	lower upper)
    (while node
      (let* ((element (avl-tree--node-data node))
	     (begin (org-element-property :begin element)))
	(cond
	 ((and limit
	       (not (org-element--cache-key-less-p
		     (org-element--cache-key element) limit)))
	  (setq node (avl-tree--node-left node)))
	 ((> begin pos)
	  (setq upper element
		node (avl-tree--node-left node)))
	 ((< begin pos)
	  (setq lower element
		node (avl-tree--node-right node)))
	 ;; We found an element in cache starting at POS.  If `side'
	 ;; is `both' we also want the next one in order to generate
	 ;; a key in-between.
	 ;;
	 ;; If the element is the first row or item in a table or
	 ;; a plain list, we always return the table or the plain
	 ;; list.
	 ;;
	 ;; In any other case, we return the element found.
	 ((eq side 'both)
	  (setq lower element)
	  (setq node (avl-tree--node-right node)))
	 ((and (memq (org-element-type element) '(item table-row))
	       (let ((parent (org-element-property :parent element)))
		 (and (= (org-element-property :begin element)
			 (org-element-property :contents-begin parent))
		      (setq node nil
			    lower parent
			    upper parent)))))
	 (t
	  (setq node nil
		lower element
		upper element)))))
    (case side
      (both (cons lower upper))
      ((nil) lower)
      (otherwise upper))))

(defun org-element--cache-put (element &optional data)
  "Store ELEMENT in current buffer's cache, if allowed.
When optional argument DATA is non-nil, assume is it object data
relative to ELEMENT and store it in the objects cache."
  (cond ((not (org-element--cache-active-p)) nil)
	((not data)
	 (when org-element--cache-sync-requests
	   ;; During synchronization, first build an appropriate key
	   ;; for the new element so `avl-tree-enter' can insert it at
	   ;; the right spot in the cache.
	   (let ((keys (org-element--cache-find
			(org-element-property :begin element) 'both)))
	     (puthash element
		      (org-element--cache-generate-key
		       (and (car keys) (org-element--cache-key (car keys)))
		       (cond ((cdr keys) (org-element--cache-key (cdr keys)))
			     (org-element--cache-sync-requests
			      (aref (car org-element--cache-sync-requests) 0))))
		      org-element--cache-sync-keys)))
	 (avl-tree-enter org-element--cache element))
	;; Headlines are not stored in cache, so objects in titles are
	;; not stored either.
	((eq (org-element-type element) 'headline) nil)
	(t (puthash element data org-element--cache-objects))))

(defsubst org-element--cache-remove (element)
  "Remove ELEMENT from cache.
Assume ELEMENT belongs to cache and that a cache is active."
  (avl-tree-delete org-element--cache element)
  (remhash element org-element--cache-objects))


;;;; Synchronization

(defsubst org-element--cache-set-timer (buffer)
  "Set idle timer for cache synchronization in BUFFER."
  (when org-element--cache-sync-timer
    (cancel-timer org-element--cache-sync-timer))
  (setq org-element--cache-sync-timer
	(run-with-idle-timer
	 (let ((idle (current-idle-time)))
	   (if idle (time-add idle org-element-cache-sync-break)
	     org-element-cache-sync-idle-time))
	 nil
	 #'org-element--cache-sync
	 buffer)))

(defsubst org-element--cache-interrupt-p (time-limit)
  "Non-nil when synchronization process should be interrupted.
TIME-LIMIT is a time value or nil."
  (and time-limit
       (or (input-pending-p)
	   (time-less-p time-limit (current-time)))))

(defsubst org-element--cache-shift-positions (element offset &optional props)
  "Shift ELEMENT properties relative to buffer positions by OFFSET.

Properties containing buffer positions are `:begin', `:end',
`:contents-begin', `:contents-end' and `:structure'.  When
optional argument PROPS is a list of keywords, only shift
properties provided in that list.

Properties are modified by side-effect."
  (let ((properties (nth 1 element)))
    ;; Shift `:structure' property for the first plain list only: it
    ;; is the only one that really matters and it prevents from
    ;; shifting it more than once.
    (when (and (or (not props) (memq :structure props))
	       (eq (org-element-type element) 'plain-list)
	       (not (eq (org-element-type (plist-get properties :parent))
			'item)))
      (dolist (item (plist-get properties :structure))
	(incf (car item) offset)
	(incf (nth 6 item) offset)))
    (dolist (key '(:begin :contents-begin :contents-end :end :post-affiliated))
      (let ((value (and (or (not props) (memq key props))
			(plist-get properties key))))
	(and value (plist-put properties key (+ offset value)))))))

(defun org-element--cache-sync (buffer &optional threshold)
  "Synchronize cache with recent modification in BUFFER.
When optional argument THRESHOLD is non-nil, do the
synchronization for all elements starting before or at threshold,
then exit.  Otherwise, synchronize cache for as long as
`org-element-cache-sync-duration' or until Emacs leaves idle
state."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-quit t) request next)
	(when org-element--cache-sync-timer
	  (cancel-timer org-element--cache-sync-timer))
	(catch 'interrupt
	  (while org-element--cache-sync-requests
	    (setq request (car org-element--cache-sync-requests)
		  next (nth 1 org-element--cache-sync-requests))
	    (or (org-element--cache-process-request
		 request
		 (and next (aref next 0))
		 threshold
		 (and (not threshold)
		      (time-add (current-time)
				org-element-cache-sync-duration)))
		(throw 'interrupt t))
	    ;; Request processed.  Merge current and next offsets and
	    ;; transfer phase number and ending position.
	    (when next
	      (incf (aref next 2) (aref request 2))
	      (aset next 1 (aref request 1))
	      (aset next 4 (aref request 4)))
	    (setq org-element--cache-sync-requests
		  (cdr org-element--cache-sync-requests))))
	;; If more requests are awaiting, set idle timer accordingly.
	;; Otherwise, reset keys.
	(if org-element--cache-sync-requests
	    (org-element--cache-set-timer buffer)
	  (clrhash org-element--cache-sync-keys))))))

(defun org-element--cache-process-request (request next threshold time-limit)
  "Process synchronization REQUEST for all entries before NEXT.

REQUEST is a vector, built by `org-element--cache-submit-request'.

NEXT is a cache key, as returned by `org-element--cache-key'.

When non-nil, THRESHOLD is a buffer position.  Synchronization
stops as soon as a shifted element begins after it.

When non-nil, TIME-LIMIT is a time value.  Synchronization stops
after this time or when Emacs exits idle state.

Return nil if the process stops before completing the request,
t otherwise."
  (catch 'quit
    (when (= (aref request 4) 0)
      ;; Phase 1.
      ;;
      ;; Delete all elements starting after BEG, but not after buffer
      ;; position END or past element with key NEXT.
      ;;
      ;; As an exception, also delete elements starting after
      ;; modifications but included in an element altered by
      ;; modifications (orphans).
      ;;
      ;; At each iteration, we start again at tree root since
      ;; a deletion modifies structure of the balanced tree.
      (catch 'end-phase
        (let ((beg (aref request 0))
              (end (aref request 1))
              (deleted-parent (aref request 3)))
          (while t
            (when (org-element--cache-interrupt-p time-limit)
	      (aset request 3 deleted-parent)
	      (throw 'quit nil))
            ;; Find first element in cache with key BEG or after it.
	    ;; We don't use `org-element--cache-find' because it
	    ;; couldn't reach orphaned elements past NEXT.  Moreover,
	    ;; BEG is a key, not a buffer position.
            (let ((node (org-element--cache-root)) data data-key)
              (while node
                (let* ((element (avl-tree--node-data node))
                       (key (org-element--cache-key element)))
                  (cond
                   ((org-element--cache-key-less-p key beg)
                    (setq node (avl-tree--node-right node)))
                   ((org-element--cache-key-less-p beg key)
                    (setq data element
                          data-key key
                          node (avl-tree--node-left node)))
                   (t (setq data element
                            data-key key
                            node nil)))))
	      (if (not data) (throw 'quit t)
		(let ((pos (org-element-property :begin data)))
		  (cond
		   ;; Remove orphaned elements.
		   ((and deleted-parent
			 (let ((up data))
			   (while (and
				   (setq up (org-element-property :parent up))
				   (not (eq up deleted-parent))))
			   up))
		    (org-element--cache-remove data))
		   ((or (and next
			     (not (org-element--cache-key-less-p data-key
								 next)))
			(> pos end))
		    (aset request 0 data-key)
		    (aset request 1 pos)
		    (aset request 4 1)
		    (throw 'end-phase nil))
		   (t (org-element--cache-remove data)
		      (when (= (org-element-property :end data) end)
			(setq deleted-parent data)))))))))))
    (when (= (aref request 4) 1)
      ;; Phase 2.
      ;;
      ;; Phase 1 left a hole in the parse tree.  Some elements after
      ;; it could have parents within.  For example, in the following
      ;; buffer:
      ;;
      ;;
      ;;   - item
      ;;
      ;;
      ;;     Paragraph1
      ;;
      ;;     Paragraph2
      ;;
      ;;
      ;; if we remove a blank line between "item" and "Paragraph1",
      ;; everything down to "Paragraph2" is removed from cache.  But
      ;; the paragraph now belongs to the list, and its `:parent'
      ;; property no longer is accurate.
      ;;
      ;; Therefore we need to parse again elements in the hole, or at
      ;; least in its last section, so that we can re-parent
      ;; subsequent elements, during phase 3.
      ;;
      ;; Note that we only need to get the parent from the first
      ;; element in cache after the hole.
      ;;
      ;; Also, this part can be delayed if we don't need to retrieve
      ;; an element after the hole.
      (catch 'end-phase
	;; Next element will start at its beginning position plus
	;; offset, since it hasn't been shifted yet.  Therefore, LIMIT
	;; contains the real beginning position of the first element
	;; to shift and re-parent.
	(when (equal (aref request 0) next) (throw 'quit t))
	(let ((limit (+ (aref request 1) (aref request 2))))
	  (when (and threshold (< threshold limit)) (throw 'quit nil))
	  (let ((parent (org-element--parse-to limit t time-limit)))
	    (if (eq parent 'interrupted) (throw 'quit nil)
	      (aset request 3 parent)
	      (aset request 4 2)
	      (throw 'end-phase nil))))))
    ;; Phase 3.
    ;;
    ;; Shift all elements starting from key START, but before NEXT, by
    ;; OFFSET, and re-parent them when appropriate.
    ;;
    ;; Elements are modified by side-effect so the tree structure
    ;; remains intact.
    ;;
    ;; Once THRESHOLD, if any, is reached, or once there is an input
    ;; pending, exit.  Before leaving, the current synchronization
    ;; request is updated.
    (let ((start (aref request 0))
	  (offset (aref request 2))
	  (parent (aref request 3))
	  (node (org-element--cache-root))
	  (stack (list nil))
	  (leftp t)
	  exit-flag)
      ;; No re-parenting nor shifting planned: request is over.
      (when (and (not parent) (zerop offset)) (throw 'quit t))
      (while node
	(let* ((data (avl-tree--node-data node))
	       (key (org-element--cache-key data)))
	  (if (and leftp (avl-tree--node-left node)
		   (not (org-element--cache-key-less-p key start)))
	      (progn (push node stack)
		     (setq node (avl-tree--node-left node)))
	    (unless (org-element--cache-key-less-p key start)
	      ;; We reached NEXT.  Request is complete.
	      (when (equal key next) (throw 'quit t))
	      ;; Handle interruption request.  Update current request.
	      (when (or exit-flag (org-element--cache-interrupt-p time-limit))
		(aset request 0 key)
		(aset request 3 parent)
		(throw 'quit nil))
	      ;; Shift element.
	      (unless (zerop offset)
		(org-element--cache-shift-positions data offset)
		;; Shift associated objects data, if any.
		(dolist (object-data (gethash data org-element--cache-objects))
		  (dolist (object (cddr object-data))
		    (org-element--cache-shift-positions object offset))))
	      (let ((begin (org-element-property :begin data)))
		;; Re-parent it.
		(while (and parent
			    (<= (org-element-property :end parent) begin))
		  (setq parent (org-element-property :parent parent)))
		(cond (parent (org-element-put-property data :parent parent))
		      ((zerop offset) (throw 'quit t)))
		;; Cache is up-to-date past THRESHOLD.  Request
		;; interruption.
		(when (and threshold (> begin threshold)) (setq exit-flag t))))
	    (setq node (if (setq leftp (avl-tree--node-right node))
			   (avl-tree--node-right node)
			 (pop stack))))))
      ;; We reached end of tree: synchronization complete.
      t)))

(defun org-element--parse-to (pos &optional syncp time-limit)
  "Parse elements in current section, down to POS.

Start parsing from the closest between the last known element in
cache or headline above.  Return the smallest element containing
POS.

When optional argument SYNCP is non-nil, return the parent of the
element containing POS instead.  In that case, it is also
possible to provide TIME-LIMIT, which is a time value specifying
when the parsing should stop.  The function returns `interrupted'
if the process stopped before finding the expected result."
  (catch 'exit
    (org-with-wide-buffer
     (goto-char pos)
     (let* ((cached (and (org-element--cache-active-p)
			 (org-element--cache-find pos nil)))
            (begin (org-element-property :begin cached))
            element next)
       (cond
        ;; Nothing in cache before point: start parsing from first
        ;; element following headline above, or first element in
        ;; buffer.
        ((not cached)
         (when (org-with-limited-levels (outline-previous-heading))
           (forward-line))
         (skip-chars-forward " \r\t\n")
         (beginning-of-line))
        ;; Cache returned exact match: return it.
        ((= pos begin)
	 (throw 'exit (if syncp (org-element-property :parent cached) cached)))
        ;; There's a headline between cached value and POS: cached
        ;; value is invalid.  Start parsing from first element
        ;; following the headline.
        ((re-search-backward
          (org-with-limited-levels org-outline-regexp-bol) begin t)
         (forward-line)
         (skip-chars-forward " \r\t\n")
         (beginning-of-line))
        ;; Check if CACHED or any of its ancestors contain point.
        ;;
        ;; If there is such an element, we inspect it in order to know
        ;; if we return it or if we need to parse its contents.
        ;; Otherwise, we just start parsing from current location,
        ;; which is right after the top-most element containing
        ;; CACHED.
        ;;
        ;; As a special case, if POS is at the end of the buffer, we
        ;; want to return the innermost element ending there.
        ;;
        ;; Also, if we find an ancestor and discover that we need to
        ;; parse its contents, make sure we don't start from
        ;; `:contents-begin', as we would otherwise go past CACHED
        ;; again.  Instead, in that situation, we will resume parsing
        ;; from NEXT, which is located after CACHED or its higher
        ;; ancestor not containing point.
        (t
         (let ((up cached)
               (pos (if (= (point-max) pos) (1- pos) pos)))
           (goto-char (or (org-element-property :contents-begin cached) begin))
           (while (let ((end (org-element-property :end up)))
                    (and (<= end pos)
                         (goto-char end)
                         (setq up (org-element-property :parent up)))))
           (cond ((not up))
                 ((eobp) (setq element up))
                 (t (setq element up next (point)))))))
       ;; Parse successively each element until we reach POS.
       (let ((end (or (org-element-property :end element)
		      (save-excursion
			(org-with-limited-levels (outline-next-heading))
			(point))))
	     (parent element)
	     special-flag)
	 (while t
	   (when syncp
	     (cond ((= (point) pos) (throw 'exit parent))
		   ((org-element--cache-interrupt-p time-limit)
		    (throw 'exit 'interrupted))))
	   (unless element
	     (setq element (org-element--current-element
			    end 'element special-flag
			    (org-element-property :structure parent)))
	     (org-element-put-property element :parent parent)
	     (org-element--cache-put element))
	   (let ((elem-end (org-element-property :end element))
		 (type (org-element-type element)))
	     (cond
	      ;; Skip any element ending before point.  Also skip
	      ;; element ending at point (unless it is also the end of
	      ;; buffer) since we're sure that another element begins
	      ;; after it.
	      ((and (<= elem-end pos) (/= (point-max) elem-end))
	       (goto-char elem-end))
	      ;; A non-greater element contains point: return it.
	      ((not (memq type org-element-greater-elements))
	       (throw 'exit element))
	      ;; Otherwise, we have to decide if ELEMENT really
	      ;; contains POS.  In that case we start parsing from
	      ;; contents' beginning.
	      ;;
	      ;; If POS is at contents' beginning but it is also at
	      ;; the beginning of the first item in a list or a table.
	      ;; In that case, we need to create an anchor for that
	      ;; list or table, so return it.
	      ;;
	      ;; Also, if POS is at the end of the buffer, no element
	      ;; can start after it, but more than one may end there.
	      ;; Arbitrarily, we choose to return the innermost of
	      ;; such elements.
	      ((let ((cbeg (org-element-property :contents-begin element))
		     (cend (org-element-property :contents-end element)))
		 (when (or syncp
			   (and cbeg cend
				(or (< cbeg pos)
				    (and (= cbeg pos)
					 (not (memq type '(plain-list table)))))
				(or (> cend pos)
				    (and (= cend pos) (= (point-max) pos)))))
		   (goto-char (or next cbeg))
		   (setq next nil
			 special-flag (case type
					(plain-list 'item)
					(property-drawer 'node-property)
					(table 'table-row))
			 parent element
			 end cend))))
	      ;; Otherwise, return ELEMENT as it is the smallest
	      ;; element containing POS.
	      (t (throw 'exit element))))
	   (setq element nil)))))))


;;;; Staging Buffer Changes

(defconst org-element--cache-opening-line
  (concat "^[ \t]*\\(?:"
	  "#\\+BEGIN[:_]" "\\|"
	  "\\\\begin{[A-Za-z0-9]+\\*?}" "\\|"
	  ":\\S-+:[ \t]*$"
	  "\\)")
  "Regexp matching an element opening line.
When such a line is modified, modifications may propagate after
modified area.  In that situation, every element between that
area and next section is removed from cache.")

(defconst org-element--cache-closing-line
  (concat "^[ \t]*\\(?:"
	  "#\\+END\\(?:_\\|:?[ \t]*$\\)" "\\|"
	  "\\\\end{[A-Za-z0-9]+\\*?}[ \t]*$" "\\|"
	  ":END:[ \t]*$"
	  "\\)")
  "Regexp matching an element closing line.
When such a line is modified, modifications may propagate before
modified area.  In that situation, every element between that
area and previous section is removed from cache.")

(defvar org-element--cache-change-warning nil
  "Non-nil when a sensitive line is about to be changed.
It is a symbol among nil, t and `headline'.")

(defun org-element--cache-before-change (beg end)
  "Request extension of area going to be modified if needed.
BEG and END are the beginning and end of the range of changed
text.  See `before-change-functions' for more information."
  (let ((inhibit-quit t))
    ;; Make sure buffer positions in cache are correct until END.
    (save-match-data
      (org-element--cache-sync (current-buffer) end)
      (org-with-wide-buffer
       (goto-char beg)
       (beginning-of-line)
       (let ((top (point))
	     (bottom (save-excursion (goto-char end) (line-end-position)))
	     (sensitive-re
	      ;; A sensitive line is a headline or a block (or drawer,
	      ;; or latex-environment) boundary.  Inserting one can
	      ;; modify buffer drastically both above and below that
	      ;; line, possibly making cache invalid.  Therefore, we
	      ;; need to pay attention to changes happening to them.
	      (concat
	       "\\(" (org-with-limited-levels org-outline-regexp-bol) "\\)" "\\|"
	       org-element--cache-closing-line "\\|"
	       org-element--cache-opening-line)))
	 (setq org-element--cache-change-warning
	       (cond ((not (re-search-forward sensitive-re bottom t)) nil)
		     ((and (match-beginning 1)
			   (progn (goto-char bottom)
				  (or (not (re-search-backward sensitive-re
							       (match-end 1) t))
				      (match-beginning 1))))
		      'headline)
		     (t))))))))

(defun org-element--cache-after-change (beg end pre)
  "Update buffer modifications for current buffer.
BEG and END are the beginning and end of the range of changed
text, and the length in bytes of the pre-change text replaced by
that range.  See `after-change-functions' for more information."
  (let ((inhibit-quit t))
    (when (org-element--cache-active-p)
      (org-with-wide-buffer
       (goto-char beg)
       (beginning-of-line)
       (let ((top (point))
	     (bottom (save-excursion (goto-char end) (line-end-position))))
	 (org-with-limited-levels
	  (save-match-data
	    ;; Determine if modified area needs to be extended,
	    ;; according to both previous and current state.  We make
	    ;; a special case for headline editing: if a headline is
	    ;; modified but not removed, do not extend.
	    (when (let ((previous-state org-element--cache-change-warning)
			(sensitive-re
			 (concat "\\(" org-outline-regexp-bol "\\)" "\\|"
				 org-element--cache-closing-line "\\|"
				 org-element--cache-opening-line))
			(case-fold-search t))
		    (cond ((eq previous-state t))
			  ((not (re-search-forward sensitive-re bottom t))
			   (eq previous-state 'headline))
			  ((match-beginning 1)
			   (or (not (eq previous-state 'headline))
			       (and (progn (goto-char bottom)
					   (re-search-backward
					    sensitive-re (match-end 1) t))
				    (not (match-beginning 1)))))
			  (t)))
	      ;; Effectively extend modified area.
	      (setq top (progn (goto-char top)
			       (when (outline-previous-heading) (forward-line))
			       (point)))
	      (setq bottom (progn (goto-char bottom)
				  (if (outline-next-heading) (1- (point))
				    (point)))))))
	 ;; Store synchronization request.
	 (let ((offset (- end beg pre)))
	   (org-element--cache-submit-request top (- bottom offset) offset))))
      ;; Activate a timer to process the request during idle time.
      (org-element--cache-set-timer (current-buffer)))))

(defun org-element--cache-submit-request (beg end offset)
  "Submit a new cache synchronization request for current buffer.
BEG and END are buffer positions delimiting the minimal area
where cache data should be removed.  OFFSET is the size of the
change, as an integer."
  (let ((first-element
	 ;; Find the position of the first element in cache to remove.
	 ;;
	 ;; Partially modified elements will be removed during request
	 ;; processing.  As an exception, greater elements around the
	 ;; changes that are robust to contents modifications are
	 ;; preserved.
	 ;;
	 ;; We look just before BEG because an element ending at BEG
	 ;; needs to be removed too.
	 (let* ((elements (org-element--cache-find (1- beg) 'both))
		(before (car elements))
		(after (cdr elements)))
	   (if (not before) after
	     (let ((up before))
	       (while (setq up (org-element-property :parent up))
		 (if (and (memq (org-element-type up)
				'(center-block
				  drawer dynamic-block inlinetask
				  property-drawer quote-block special-block))
			  (<= (org-element-property :contents-begin up) beg)
			  (> (org-element-property :contents-end up) end))
		     ;; UP is a greater element that is wrapped around
		     ;; the changes.  We only need to extend its
		     ;; ending boundaries and those of all its
		     ;; parents.
		     (while up
		       (org-element--cache-shift-positions
			up offset '(:contents-end :end))
		       (setq up (org-element-property :parent up)))
		   (setq before up)))
	       ;; We're at top level element containing ELEMENT: if
	       ;; it's altered by buffer modifications, it is first
	       ;; element in cache to be removed.  Otherwise, that
	       ;; first element is the following one.
	       (if (< (org-element-property :end before) beg) after before))))))
    (cond
     ;; Changes happened before the first known element.  Shift the
     ;; rest of the cache.
     ((and first-element (> (org-element-property :begin first-element) end))
      (push (vector (org-element--cache-key first-element) nil offset nil 2)
	    org-element--cache-sync-requests))
     ;; There is at least an element to remove.  Find position past
     ;; every element containing END.
     (first-element
      (if (> (org-element-property :end first-element) end)
	  (setq end (org-element-property :end first-element))
	(let ((element (org-element--cache-find end)))
	  (setq end (org-element-property :end element))
	  (let ((up element))
	    (while (and (setq up (org-element-property :parent up))
			(>= (org-element-property :begin up) beg))
	      (setq end (org-element-property :end up))))))
      (push (vector (org-element--cache-key first-element) end offset nil 0)
	    org-element--cache-sync-requests))
     ;; No element to remove.  No need to re-parent either.  Simply
     ;; shift additional elements, if any, by OFFSET.
     (org-element--cache-sync-requests
      (incf (aref (car org-element--cache-sync-requests) 2) offset)))))


;;;; Public Functions

;;;###autoload
(defun org-element-cache-reset (&optional all)
  "Reset cache in current buffer.
When optional argument ALL is non-nil, reset cache in all Org
buffers."
  (interactive "P")
  (dolist (buffer (if all (buffer-list) (list (current-buffer))))
    (with-current-buffer buffer
      (when (org-element--cache-active-p)
	(org-set-local 'org-element--cache
		       (avl-tree-create #'org-element--cache-compare))
	(org-set-local 'org-element--cache-objects (make-hash-table :test #'eq))
	(org-set-local 'org-element--cache-sync-keys
		       (make-hash-table :weakness 'key :test #'eq))
	(org-set-local 'org-element--cache-change-warning nil)
	(org-set-local 'org-element--cache-sync-requests nil)
	(org-set-local 'org-element--cache-sync-timer nil)
	(add-hook 'before-change-functions
		  #'org-element--cache-before-change nil t)
	(add-hook 'after-change-functions
		  #'org-element--cache-after-change nil t)))))

;;;###autoload
(defun org-element-cache-refresh (pos)
  "Refresh cache at position POS."
  (when (org-element--cache-active-p)
    (org-element--cache-sync (current-buffer) pos)
    (org-element--cache-submit-request pos pos 0)
    (org-element--cache-set-timer (current-buffer))))



;;; The Toolbox
;;
;; The first move is to implement a way to obtain the smallest element
;; containing point.  This is the job of `org-element-at-point'.  It
;; basically jumps back to the beginning of section containing point
;; and proceed, one element after the other, with
;; `org-element--current-element' until the container is found.  Note:
;; When using `org-element-at-point', secondary values are never
;; parsed since the function focuses on elements, not on objects.
;;
;; At a deeper level, `org-element-context' lists all elements and
;; objects containing point.
;;
;; `org-element-nested-p' and `org-element-swap-A-B' may be used
;; internally by navigation and manipulation tools.


;;;###autoload
(defun org-element-at-point ()
  "Determine closest element around point.

Return value is a list like (TYPE PROPS) where TYPE is the type
of the element and PROPS a plist of properties associated to the
element.

Possible types are defined in `org-element-all-elements'.
Properties depend on element or object type, but always include
`:begin', `:end', `:parent' and `:post-blank' properties.

As a special case, if point is at the very beginning of the first
item in a list or sub-list, returned element will be that list
instead of the item.  Likewise, if point is at the beginning of
the first row of a table, returned element will be the table
instead of the first row.

When point is at the end of the buffer, return the innermost
element ending there."
  (org-with-wide-buffer
   (let ((origin (point)))
     (end-of-line)
     (skip-chars-backward " \r\t\n")
     (cond
      ;; Within blank lines at the beginning of buffer, return nil.
      ((bobp) nil)
      ;; Within blank lines right after a headline, return that
      ;; headline.
      ((org-with-limited-levels (org-at-heading-p))
       (beginning-of-line)
       (org-element-headline-parser (point-max) t))
      ;; Otherwise parse until we find element containing ORIGIN.
      (t
       (when (org-element--cache-active-p)
	 (if (not org-element--cache) (org-element-cache-reset)
	   (org-element--cache-sync (current-buffer) origin)))
       (org-element--parse-to origin))))))

;;;###autoload
(defun org-element-context (&optional element)
  "Return smallest element or object around point.

Return value is a list like (TYPE PROPS) where TYPE is the type
of the element or object and PROPS a plist of properties
associated to it.

Possible types are defined in `org-element-all-elements' and
`org-element-all-objects'.  Properties depend on element or
object type, but always include `:begin', `:end', `:parent' and
`:post-blank'.

As a special case, if point is right after an object and not at
the beginning of any other object, return that object.

Optional argument ELEMENT, when non-nil, is the closest element
containing point, as returned by `org-element-at-point'.
Providing it allows for quicker computation."
  (catch 'objects-forbidden
    (org-with-wide-buffer
     (let* ((pos (point))
	    (element (or element (org-element-at-point)))
	    (type (org-element-type element)))
       ;; If point is inside an element containing objects or
       ;; a secondary string, narrow buffer to the container and
       ;; proceed with parsing.  Otherwise, return ELEMENT.
       (cond
	;; At a parsed affiliated keyword, check if we're inside main
	;; or dual value.
	((let ((post (org-element-property :post-affiliated element)))
	   (and post (< pos post)))
	 (beginning-of-line)
	 (let ((case-fold-search t)) (looking-at org-element--affiliated-re))
	 (cond
	  ((not (member-ignore-case (match-string 1)
				    org-element-parsed-keywords))
	   (throw 'objects-forbidden element))
	  ((< (match-end 0) pos)
	   (narrow-to-region (match-end 0) (line-end-position)))
	  ((and (match-beginning 2)
		(>= pos (match-beginning 2))
		(< pos (match-end 2)))
	   (narrow-to-region (match-beginning 2) (match-end 2)))
	  (t (throw 'objects-forbidden element)))
	 ;; Also change type to retrieve correct restrictions.
	 (setq type 'keyword))
	;; At an item, objects can only be located within tag, if any.
	((eq type 'item)
	 (let ((tag (org-element-property :tag element)))
	   (if (not tag) (throw 'objects-forbidden element)
	     (beginning-of-line)
	     (search-forward tag (line-end-position))
	     (goto-char (match-beginning 0))
	     (if (and (>= pos (point)) (< pos (match-end 0)))
		 (narrow-to-region (point) (match-end 0))
	       (throw 'objects-forbidden element)))))
	;; At an headline or inlinetask, objects are in title.
	((memq type '(headline inlinetask))
	 (goto-char (org-element-property :begin element))
	 (skip-chars-forward "*")
	 (if (and (> pos (point)) (< pos (line-end-position)))
	     (narrow-to-region (point) (line-end-position))
	   (throw 'objects-forbidden element)))
	;; At a paragraph, a table-row or a verse block, objects are
	;; located within their contents.
	((memq type '(paragraph table-row verse-block))
	 (let ((cbeg (org-element-property :contents-begin element))
	       (cend (org-element-property :contents-end element)))
	   ;; CBEG is nil for table rules.
	   (if (and cbeg cend (>= pos cbeg)
		    (or (< pos cend) (and (= pos cend) (eobp))))
	       (narrow-to-region cbeg cend)
	     (throw 'objects-forbidden element))))
	;; At a parsed keyword, objects are located within value.
	((eq type 'keyword)
	 (if (not (member (org-element-property :key element)
			  org-element-document-properties))
	     (throw 'objects-forbidden element)
	   (beginning-of-line)
	   (search-forward ":")
	   (if (and (>= pos (point)) (< pos (line-end-position)))
	       (narrow-to-region (point) (line-end-position))
	     (throw 'objects-forbidden element))))
	;; At a planning line, if point is at a timestamp, return it,
	;; otherwise, return element.
	((eq type 'planning)
	 (dolist (p '(:closed :deadline :scheduled))
	   (let ((timestamp (org-element-property p element)))
	     (when (and timestamp
			(<= (org-element-property :begin timestamp) pos)
			(> (org-element-property :end timestamp) pos))
	       (throw 'objects-forbidden timestamp))))
	 ;; All other locations cannot contain objects: bail out.
	 (throw 'objects-forbidden element))
	(t (throw 'objects-forbidden element)))
       (goto-char (point-min))
       (let ((restriction (org-element-restriction type))
	     (parent element)
	     (cache (cond ((not (org-element--cache-active-p)) nil)
			  (org-element--cache-objects
			   (gethash element org-element--cache-objects))
			  (t (org-element-cache-reset) nil)))
	     next object-data last)
	 (prog1
	     (catch 'exit
	       (while t
		 ;; When entering PARENT for the first time, get list
		 ;; of objects within known so far.  Store it in
		 ;; OBJECT-DATA.
		 (unless next
		   (let ((data (assq parent cache)))
		     (if data (setq object-data data)
		       (push (setq object-data (list parent nil)) cache))))
		 ;; Find NEXT object for analysis.
		 (catch 'found
		   ;; If NEXT is non-nil, we already exhausted the
		   ;; cache so we can parse buffer to find the object
		   ;; after it.
		   (if next (setq next (org-element--object-lex restriction))
		     ;; Otherwise, check if cache can help us.
		     (let ((objects (cddr object-data))
			   (completep (nth 1 object-data)))
		       (cond
			((and (not objects) completep) (throw 'exit parent))
			((not objects)
			 (setq next (org-element--object-lex restriction)))
			(t
			 (let ((cache-limit
				(org-element-property :end (car objects))))
			   (if (>= cache-limit pos)
			       ;; Cache contains the information needed.
			       (dolist (object objects (throw 'exit parent))
				 (when (<= (org-element-property :begin object)
					   pos)
				   (if (>= (org-element-property :end object)
					   pos)
				       (throw 'found (setq next object))
				     (throw 'exit parent))))
			     (goto-char cache-limit)
			     (setq next
				   (org-element--object-lex restriction))))))))
		   ;; If we have a new object to analyze, store it in
		   ;; cache.  Otherwise record that there is nothing
		   ;; more to parse in this element at this depth.
		   (if next
		       (progn (org-element-put-property next :parent parent)
			      (push next (cddr object-data)))
		     (setcar (cdr object-data) t)))
		 ;; Process NEXT, if any, in order to know if we need
		 ;; to skip it, return it or move into it.
		 (if (or (not next) (> (org-element-property :begin next) pos))
		     (throw 'exit (or last parent))
		   (let ((end (org-element-property :end next))
			 (cbeg (org-element-property :contents-begin next))
			 (cend (org-element-property :contents-end next)))
		     (cond
		      ;; Skip objects ending before point.  Also skip
		      ;; objects ending at point unless it is also the
		      ;; end of buffer, since we want to return the
		      ;; innermost object.
		      ((and (<= end pos) (/= (point-max) end))
		       (goto-char end)
		       ;; For convenience, when object ends at POS,
		       ;; without any space, store it in LAST, as we
		       ;; will return it if no object starts here.
		       (when (and (= end pos)
				  (not (memq (char-before) '(?\s ?\t))))
			 (setq last next)))
		      ;; If POS is within a container object, move
		      ;; into that object.
		      ((and cbeg cend
			    (>= pos cbeg)
			    (or (< pos cend)
				;; At contents' end, if there is no
				;; space before point, also move into
				;; object, for consistency with
				;; convenience feature above.
				(and (= pos cend)
				     (or (= (point-max) pos)
					 (not (memq (char-before pos)
						    '(?\s ?\t)))))))
		       (goto-char cbeg)
		       (narrow-to-region (point) cend)
		       (setq parent next
			     restriction (org-element-restriction next)
			     next nil
			     object-data nil))
		      ;; Otherwise, return NEXT.
		      (t (throw 'exit next)))))))
	   ;; Store results in cache, if applicable.
	   (org-element--cache-put element cache)))))))

(defun org-element-nested-p (elem-A elem-B)
  "Non-nil when elements ELEM-A and ELEM-B are nested."
  (let ((beg-A (org-element-property :begin elem-A))
	(beg-B (org-element-property :begin elem-B))
	(end-A (org-element-property :end elem-A))
	(end-B (org-element-property :end elem-B)))
    (or (and (>= beg-A beg-B) (<= end-A end-B))
	(and (>= beg-B beg-A) (<= end-B end-A)))))

(defun org-element-swap-A-B (elem-A elem-B)
  "Swap elements ELEM-A and ELEM-B.
Assume ELEM-B is after ELEM-A in the buffer.  Leave point at the
end of ELEM-A."
  (goto-char (org-element-property :begin elem-A))
  ;; There are two special cases when an element doesn't start at bol:
  ;; the first paragraph in an item or in a footnote definition.
  (let ((specialp (not (bolp))))
    ;; Only a paragraph without any affiliated keyword can be moved at
    ;; ELEM-A position in such a situation.  Note that the case of
    ;; a footnote definition is impossible: it cannot contain two
    ;; paragraphs in a row because it cannot contain a blank line.
    (if (and specialp
	     (or (not (eq (org-element-type elem-B) 'paragraph))
		 (/= (org-element-property :begin elem-B)
		     (org-element-property :contents-begin elem-B))))
	(error "Cannot swap elements"))
    ;; In a special situation, ELEM-A will have no indentation.  We'll
    ;; give it ELEM-B's (which will in, in turn, have no indentation).
    (let* ((ind-B (when specialp
		    (goto-char (org-element-property :begin elem-B))
		    (org-get-indentation)))
	   (beg-A (org-element-property :begin elem-A))
	   (end-A (save-excursion
		    (goto-char (org-element-property :end elem-A))
		    (skip-chars-backward " \r\t\n")
		    (point-at-eol)))
	   (beg-B (org-element-property :begin elem-B))
	   (end-B (save-excursion
		    (goto-char (org-element-property :end elem-B))
		    (skip-chars-backward " \r\t\n")
		    (point-at-eol)))
	   ;; Store overlays responsible for visibility status.  We
	   ;; also need to store their boundaries as they will be
	   ;; removed from buffer.
	   (overlays
	    (cons
	     (mapcar (lambda (ov) (list ov (overlay-start ov) (overlay-end ov)))
		     (overlays-in beg-A end-A))
	     (mapcar (lambda (ov) (list ov (overlay-start ov) (overlay-end ov)))
		     (overlays-in beg-B end-B))))
	   ;; Get contents.
	   (body-A (buffer-substring beg-A end-A))
	   (body-B (delete-and-extract-region beg-B end-B)))
      (goto-char beg-B)
      (when specialp
	(setq body-B (replace-regexp-in-string "\\`[ \t]*" "" body-B))
	(org-indent-to-column ind-B))
      (insert body-A)
      ;; Restore ex ELEM-A overlays.
      (let ((offset (- beg-B beg-A)))
	(mapc (lambda (ov)
		(move-overlay
		 (car ov) (+ (nth 1 ov) offset) (+ (nth 2 ov) offset)))
	      (car overlays))
	(goto-char beg-A)
	(delete-region beg-A end-A)
	(insert body-B)
	;; Restore ex ELEM-B overlays.
	(mapc (lambda (ov)
		(move-overlay
		 (car ov) (- (nth 1 ov) offset) (- (nth 2 ov) offset)))
	      (cdr overlays)))
      (goto-char (org-element-property :end elem-B)))))

(defun org-element-remove-indentation (s &optional n)
  "Remove maximum common indentation in string S and return it.
When optional argument N is a positive integer, remove exactly
that much characters from indentation, if possible, or return
S as-is otherwise.  Unlike to `org-remove-indentation', this
function doesn't call `untabify' on S."
  (catch 'exit
    (with-temp-buffer
      (insert s)
      (goto-char (point-min))
      ;; Find maximum common indentation, if not specified.
      (setq n (or n
                  (let ((min-ind (point-max)))
		    (save-excursion
		      (while (re-search-forward "^[ \t]*\\S-" nil t)
			(let ((ind (1- (current-column))))
			  (if (zerop ind) (throw 'exit s)
			    (setq min-ind (min min-ind ind))))))
		    min-ind)))
      (if (zerop n) s
	;; Remove exactly N indentation, but give up if not possible.
	(while (not (eobp))
	  (let ((ind (progn (skip-chars-forward " \t") (current-column))))
	    (cond ((eolp) (delete-region (line-beginning-position) (point)))
		  ((< ind n) (throw 'exit s))
		  (t (org-indent-line-to (- ind n))))
	    (forward-line)))
	(buffer-string)))))



(provide 'org-element)

;; Local variables:
;; generated-autoload-file: "org-loaddefs.el"
;; End:

;;; org-element.el ends here
