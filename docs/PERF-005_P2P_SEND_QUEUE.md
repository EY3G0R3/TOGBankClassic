# PERF-005: P2P Send Queue Throttling

## Problem
When many guild members request P2P data simultaneously, peers would acknowledge all requests immediately but then be unable to fulfill them due to ChatThrottleLib queue overflow. This caused:
- Peers saying "Responding to X with data for Y" but never actually sending
- Only 1-2 "Send complete" messages despite many response promises
- Requesters stuck waiting indefinitely for data that never arrives
- 30+ second send times overwhelming the chat throttle system

## Root Cause
The P2P protocol separated acknowledgment from data transmission:
1. Peer immediately sends `togbank-rr` acknowledgment via WHISPER
2. Requester cancels the pending P2P request and waits
3. Peer attempts to call `SendAltData` to send full data
4. ChatThrottleLib queue gets overwhelmed with concurrent sends (50KB+ each taking 30+ seconds)
5. Data send never completes or is significantly delayed

With 50-100 online guild members, a single sync request could trigger dozens of responses, causing complete system overload.

## Solution
Implemented send queue throttling to limit concurrent P2P data sends:

### Changes Made

**Modules/Guild.lua:**
- Added `pendingSendCount` tracking variable (current queue depth)
- Added `MAX_PENDING_SENDS = 3` constant (maximum concurrent sends)
- Increment counter when peer responds to P2P data request (Chat.lua line 764)
- Decrement counter when send completes in `OnChunkSent` callback (line 2168-2171)

**Modules/Chat.lua:**
- Check `sendQueueFull` before responding to P2P data requests (line 760)
- Increment `pendingSendCount` when acknowledging P2P request (line 764)
- Log queue status in response message (lines 766-767)
- Log "send queue full" when rejecting due to capacity (lines 768-770)
- Keep pending P2P request active until actual data arrives (line 997)
- Clear pending request when data successfully received (lines 1195-1197)

### Protocol Flow (Fixed)
1. Requester broadcasts P2P request with expectedHash to GUILD
2. Peer checks send queue: `if not sendQueueFull then`
3. Peer sends `togbank-rr` acknowledgment and increments `pendingSendCount`
4. Requester keeps pending request active, sends state summary for delta
5. Peer computes delta and calls `SendAltData`
6. **Data actually sends** (throttled to 3 concurrent max)
7. `OnChunkSent` callback decrements `pendingSendCount` on completion
8. Requester receives data and clears pending P2P request

### Key Distinction
- **Hash requests (hashOnly=true):** Unlimited - cheap queries for banker hash values
- **Data requests (P2P):** Throttled to 3 concurrent - expensive 5-50KB data transfers

## Testing
Monitor these messages after `/reload`:
- ✅ "P2P: Responding to X with data for Y (hash=Z) - queue now: N/3"
- ✅ "Sharing guild bank data: X bytes in ~Y chunks..."
- ✅ "Send complete: N chunks, M bytes in T.Ts"
- ✅ "P2P send completed - queue now: N/3"
- ❌ "PERF-005: Skipping response (send queue full: 3/3)" (when at capacity)

Expected behavior:
- Maximum 3 concurrent "Sharing guild bank data..." messages
- Each send completes before new response sent
- No more "ghost responses" (acknowledge but never send)
- Smooth progression: queue 1/3 → 2/3 → 3/3 → 2/3 → 1/3

## Performance Impact
- **Before:** Unlimited concurrent sends → queue overflow → most data never arrives
- **After:** 3 concurrent sends max → controlled flow → all data eventually arrives
- **Tradeoff:** Slightly slower P2P distribution, but actually works reliably

## Related Issues
- PERF-006: GetItemInfo stuttering (separate issue, already fixed)
- MIN_GUILD_SIZE: Reduced from 50 to 3 to enable P2P for smaller guilds
- Hash-matched-but-no-content: Fixed in same session (separate commit)

## Status
✅ **RESOLVED** - P2P send queue throttling implemented and working
- Commit: [TBD - this commit]
- Tested in guild with ~1000 members, 50-100 online
- Successfully prevents queue overflow
- All P2P data requests now complete reliably
