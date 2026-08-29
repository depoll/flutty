# Upstream source

This package is vendored from Flutter packages commit `2d177abfe0255b27d05e93d1dd8b21c7a4214307`, pull request https://github.com/flutter/packages/pull/12640.

It adds a single-reply guard around asynchronous Play Billing callbacks to prevent `IllegalStateException: Reply already submitted` when Play Billing invokes the same listener twice. Replace this directory with the released `in_app_purchase_android` package once that fix ships on pub.dev.
