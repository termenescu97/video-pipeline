# Research: Test Card Preparation

## Decision 1: File copy mechanism

**Decision**: Use Dart's `File.copy()` for copying test files to cards. No need for robocopy — test files are small (~50-100MB each) and we don't need resumable transfers for a prep utility.

**Rationale**: `File.copy()` is simple, cross-platform for development, and fast for small files. Robocopy would be overkill and add subprocess overhead for a simple copy operation.

## Decision 2: Existing DCIM/100TEST/ handling

**Decision**: Delete and recreate `DCIM/100TEST/` if it exists, then copy fresh files. This ensures a clean state for each test session.

**Rationale**: Appending would accumulate old test files. Deleting only the test folder is safe — `100TEST` is clearly a test directory, not real footage (which lives in `100CANON`, `101CANON`, etc.).
