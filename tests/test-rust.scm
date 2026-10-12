;;; Rust application defaults are configuration facts, not moving channel aliases.

(use-modules (guix packages)
             (guixcfg apps model)
             (guixcfg apps rust definition)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))
(test-begin "rust")

(test-equal "direct stable version is fixed" "1.99.0" %rust-version)
(test-equal "direct nightly version is fixed" "nightly-2026-10-10"
            %rust-nightly-version)
(test-assert "rust contributes one configured proxy package"
  (let ((packages (application-home-packages %rust)))
    (and (= 1 (length packages))
         (string=? "rust-toolchain-proxies" (package-name (car packages))))))

(test-end "rust")
