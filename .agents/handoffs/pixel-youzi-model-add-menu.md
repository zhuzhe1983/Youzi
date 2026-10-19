# Model add menu

- Pixel / local Mac, branch `fix/youzi-model-add-menu`; Atlas integrates for 0.14.5. Role files are absent.
- Chat/audio/image/video use the same search toolbar: refresh and Add model. Local opens the matching Model Files category; remote opens the existing editor.
- Removed the redundant Available models heading and footer explanation. Only cached, app-managed model files expose the delete control; loaded/in-flight safeguards remain unchanged.
- Reuse server configuration copies the URL, HTTP option and a credential through the existing same-origin Keychain guard. Model selection and parameters remain separate. Picker entries include the API base plus the source name so different credentials at the same base are not silently conflated.
- Verification: 63 focused router, model table, remote configuration and preference tests passed; native navigation and absent delete controls must be checked on the integrated package.
- No endpoint calls, key writes, downloads or deletions are required for UI acceptance.
