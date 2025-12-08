# GBankClassic - Revived

## [v2.3.0](https://github.com/GrumpyPlayer/GBankClassic/tree/v2.3.0) (2025-10-27)
[Full Changelog](https://github.com/GrumpyPlayer/GBankClassic/compare/v2.2.0...v2.3.0) [Previous Releases](https://github.com/GrumpyPlayer/GBankClassic/releases)

- Merge pull request #3 from GrumpyPlayer/merge/fix-search-normalization-into-handle-malformed-data  
    Merge/fix search normalization into handle malformed data  
- fix issues related to clean-up and init, and also allow GM to author /bank roster updates  
- Merge PR #1 (fix-search-normalization) into integration branch  
- Perform cleanup of malformed data on addon initialization and handle malformed data better  
- Fix nil version comparison in ReceiveAltData  
    - Added nil check for existing alt data version before comparison  
    - Prevents 'attempt to compare number with nil' error  
    - Fixes crash when receiving data for alts without version field  
- Fix Search.lua crash and implement name normalization with security improvements  
    - Fixed nil table index crash in Search.lua duplicate detection  
    - Added NormalizePlayerName helper for consistent 'Name-Realm' format  
    - Implemented sender authentication to prevent communication spoofing  
    - Added debug tools: /bank debug toggle and /bank debugdump command  
    - Auto-enable bank reporting for detected bank characters  
    - Relaxed delegation policy for multi-bank account support  
    - Normalized player keys across all modules for data consistency  
