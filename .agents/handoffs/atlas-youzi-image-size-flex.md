# Atlas / Pixel — Flexible image sizes

Local Mac; branch fix/youzi-image-size-flex. Native image tool incorrectly enforced 64-pixel alignment while Python parse_image_size accepts multiples of 16. The user's 1920×1080 request failed before reaching the engine. Align valid positive dimensions to the nearest legal 16-pixel value within 256...2048, report requested/effective size to the agent and directly on the artifact card. No resampling, repeated inference or global-default mutation.

32 tests passed across tools and artifact receipts, including one-call alignment, actual receipt fields, alternative separators, boundaries and malformed inputs. Final native install/visual acceptance pending integrated delivery. Runtime code unchanged.
