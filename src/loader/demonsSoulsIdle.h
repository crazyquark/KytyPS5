#pragma once

#include "common/abi.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <cstdint>
#include <span>
#include <string_view>

#if defined(__x86_64__) || defined(_M_X64)
#ifndef XBYAK_NO_EXCEPTION
#define XBYAK_NO_EXCEPTION
#endif
#include <xbyak/xbyak.h>
#endif

namespace Loader {
struct Program;
namespace DemonsSoulsIdle {
void Install(Program* program);
void Clear();

// The job workers' idle loop as every build seen has it (01.005.000 and 01.007.000): the call of the poll for
// work, the test of its result and the loop back, the call's displacement left out (IdleCallAt: the call's
// offset in it); and the poll's prologue, its frame size left out (01.005.000 0x98 bytes, 01.007.000 0x88).
inline constexpr std::string_view IdleCall = "48 89 df 4c 89 f6 48 c7 45 c8 00 00 00 00 e8 ?? ?? ?? ?? 84 c0 74 d7 "
                                             "4c 8b 7d c8 49 8b b7 90 00 00 00 48 85 f6 74";
inline constexpr size_t           IdleCallAt   = 14;
inline constexpr std::string_view PollPrologue = "55 48 89 e5 41 57 41 56 41 55 41 54 53 48 81 ec ?? ?? ?? ?? 4c 8b 35";

// The wait for work the idle loop calls before its poll: it scans the job queues, then `pause`, reads the TSC (a helper
// call) and goes round again until the worker has been idle for twice the TSC frequency (2 s) before it blocks. Work
// comes every frame, so a worker spins at ~98% of a CPU all through play (01.007.000: eboot+0x83b6fd); the helper call
// then sleeps first (KYTY_SPIN_BACKOFF_US, default 50 us). The pause, the load of the worker's last activity time, the
// helper call (SpinCallAt: the call's offset), the elapsed-time test.
inline constexpr std::string_view SpinCall   = "f3 90 4e 8b bc f3 10 0e 00 00 e8 ?? ?? ?? ?? 4c 29 f8 48 85 c0 0f 8e";
inline constexpr size_t           SpinCallAt = 10;
// The TSC helper it calls: rdtsc; shl rdx, 32; or rax, rdx; ret.
inline constexpr std::string_view TscHelper = "0f 31 48 c1 e2 20 48 09 d0 c3";

// The job workers' ticket wait (01.005.000 eboot+0xbcdcc0, 01.007.000 eboot+0xbed690): a worker takes a ticket
// (lock xadd [rbx+0x694]), then reads, without a pause, whether the items published (0x698) reach it or the batch is
// stopped (0x690) - one load each round, ~13% of the job threads' samples standing at Boletaria 1-1 on the Deck.
// The ticket, two-byte nop, then the loop: cmp eax,[rbx+A]; jl work; cmp dword [rbx+B],0; je loop (TicketLoopAt).
inline constexpr std::string_view TicketWait = "f0 0f c1 83 ?? ?? ?? ?? 66 90 3b 83 ?? ?? ?? ?? 7c ?? 83 bb ?? ?? ?? ?? 00 74 ef";
inline constexpr size_t           TicketLoopAt = 10, TicketLoopSize = 17;

#if defined(__x86_64__) || defined(_M_X64)
// The ticket wait's stand-in, jumped to from the loop's head (`loop` .. `loop` + TicketLoopSize): with `*backoff_us` 0
// the game's loop as it is; else `pause` each round and, every `spins` rounds, `sleep` (every register and the flags
// kept, the red zone left alone). It leaves for the loop's two exits with the flags their compare made.
inline void EmitTicketWait(Xbyak::CodeGenerator& c, uint64_t loop, const std::atomic<int64_t>* backoff_us,
                           const void* sleep, uint32_t spins) {
	using namespace Xbyak::util;
	int32_t items = 0, stop = 0;
	int8_t  to_work = 0;
	std::memcpy(&items, reinterpret_cast<const void*>(loop + 2), sizeof(items));
	std::memcpy(&to_work, reinterpret_cast<const void*>(loop + 7), sizeof(to_work));
	std::memcpy(&stop, reinterpret_cast<const void*>(loop + 10), sizeof(stop));
	const auto* work = reinterpret_cast<const void*>(loop + 8 + to_work);
	const auto* exit = reinterpret_cast<const void*>(loop + TicketLoopSize);
	Xbyak::Label original, spin, sleep_now, leave_work, leave_exit;
	c.push(rcx);
	c.mov(rcx, reinterpret_cast<uint64_t>(backoff_us));
	c.cmp(qword[rcx], 0);
	c.pop(rcx);
	c.je(original, Xbyak::CodeGenerator::T_NEAR);
	c.lea(rsp, ptr[rsp - 128]); // the red zone
	c.push(rcx);
	c.xor_(ecx, ecx);
	c.L(spin);
	c.cmp(eax, dword[rbx + items]);
	c.jl(leave_work, Xbyak::CodeGenerator::T_NEAR);
	c.cmp(dword[rbx + stop], 0);
	c.jne(leave_exit, Xbyak::CodeGenerator::T_NEAR);
	c.pause();
	c.inc(ecx);
	c.cmp(ecx, spins);
	c.jae(sleep_now, Xbyak::CodeGenerator::T_NEAR);
	c.jmp(spin);
	c.L(sleep_now);
	c.xor_(ecx, ecx);
	c.pushfq();
	for (const auto& reg: {rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, rbp})
		c.push(reg);
	c.mov(rbp, rsp);
	c.and_(rsp, -64);
	c.sub(rsp, 512);
	constexpr uint8_t save_fp[] {0x48, 0x0f, 0xae, 0x04, 0x24}; // FXSAVE64 [rsp]
	c.db(save_fp, sizeof(save_fp));
	c.mov(rax, reinterpret_cast<uint64_t>(sleep));
	c.call(rax);
	c.fxrstor64(ptr[rsp]);
	c.mov(rsp, rbp);
	for (const auto& reg: {rbp, r11, r10, r9, r8, rdi, rsi, rdx, rcx, rax})
		c.pop(reg);
	c.popfq();
	c.jmp(spin);
	c.L(leave_work);
	c.pop(rcx);
	c.lea(rsp, ptr[rsp + 128]);
	c.cmp(eax, dword[rbx + items]); // the items only grow: still less, as the jl found
	c.jmp(work, Xbyak::CodeGenerator::T_NEAR);
	c.L(leave_exit);
	c.pop(rcx);
	c.lea(rsp, ptr[rsp + 128]);
	c.cmp(dword[rbx + stop], 0);
	c.jmp(exit, Xbyak::CodeGenerator::T_NEAR);
	c.L(original);
	c.cmp(eax, dword[rbx + items]);
	c.jl(work);
	c.cmp(dword[rbx + stop], 0);
	c.je(original);
	c.jmp(exit, Xbyak::CodeGenerator::T_NEAR);
}

// The poll's observable register state is retained even on the idle path.
// In particular this is not an ordinary C++ function replacement: its caller
// may rely on registers the original poll was known not to modify.
inline void EmitThunk(Xbyak::CodeGenerator& c, const void* poll, const void* sleep) {
	using namespace Xbyak::util;
	Xbyak::Label done;
	c.sub(rsp, 8);
	c.call(poll);
	c.add(rsp, 8);
	c.test(al, al);
	c.jnz(done, Xbyak::CodeGenerator::T_NEAR);
	c.pushfq();
	for (const auto& reg: {rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11})
		c.push(reg);
	// Entry RSP is 8 mod 16; the 80-byte save above retains that alignment.
	c.sub(rsp, 520);
	constexpr uint8_t save_fp[] {0x48, 0x0f, 0xae, 0x04, 0x24}; // FXSAVE64 [rsp]
	c.db(save_fp, sizeof(save_fp));
	c.mov(rax, reinterpret_cast<uint64_t>(sleep));
	c.call(rax); // Explicit SysV callback bridges to the platform sleep API.
	c.fxrstor64(ptr[rsp]);
	c.add(rsp, 520);
	for (const auto& reg: {r11, r10, r9, r8, rdi, rsi, rdx, rcx, rax})
		c.pop(reg);
	c.popfq();
	c.L(done);
	c.ret();
}

// The TSC helper's stand-in in the wait for work: the backoff (its own call, every register but RAX and RDX and the
// flags kept), then the helper's own result (RAX = the TSC, RDX = its high half shifted, the flags of the OR).
inline void EmitSpinThunk(Xbyak::CodeGenerator& c, const void* backoff) {
	using namespace Xbyak::util;
	c.pushfq();
	for (const auto& reg: {rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11})
		c.push(reg);
	// Entry RSP is 8 mod 16; the 80-byte save keeps that, the 520 bytes make it 0 for FXSAVE and the call.
	c.sub(rsp, 520);
	constexpr uint8_t save_fp[] {0x48, 0x0f, 0xae, 0x04, 0x24}; // FXSAVE64 [rsp]
	c.db(save_fp, sizeof(save_fp));
	c.mov(rax, reinterpret_cast<uint64_t>(backoff));
	c.call(rax); // Explicit SysV callback bridges to the platform sleep API.
	c.fxrstor64(ptr[rsp]);
	c.add(rsp, 520);
	for (const auto& reg: {r11, r10, r9, r8, rdi, rsi, rdx, rcx, rax})
		c.pop(reg);
	c.popfq();
	c.rdtsc();
	c.shl(rdx, 32);
	c.or_(rax, rdx);
	c.ret();
}
#endif
} // namespace DemonsSoulsIdle
} // namespace Loader
