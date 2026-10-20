; MSVC's function entry and exit hooks (/Gh, /GH) for a
; GITGUD_PROFILE_INSTRUMENT build: they run before the function has saved
; anything, so every volatile register is kept, and the hook's return address
; (inside the instrumented function) goes to GitgudPenter / GitgudPexit
; (ProfilerInstrument.cpp).
;
; The stack is aligned here before the call, as the x64 convention needs:
; _penter comes before the function's prologue and _pexit after it, so the
; two arrive differently aligned. A fixed offset left one 8 off, which only
; crashed once a capture ran code that keeps SSE values on the stack.

extern GitgudPenter:proc
extern GitgudPexit:proc

HOOK macro name, target
name proc
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 80h
    movdqu [rsp+20h], xmm0
    movdqu [rsp+30h], xmm1
    movdqu [rsp+40h], xmm2
    movdqu [rsp+50h], xmm3
    movdqu [rsp+60h], xmm4
    movdqu [rsp+70h], xmm5
    mov rcx, [rbp+40h]
    call target
    movdqu xmm0, [rsp+20h]
    movdqu xmm1, [rsp+30h]
    movdqu xmm2, [rsp+40h]
    movdqu xmm3, [rsp+50h]
    movdqu xmm4, [rsp+60h]
    movdqu xmm5, [rsp+70h]
    mov rsp, rbp
    pop rbp
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret
name endp
endm

.code
HOOK _penter, GitgudPenter
HOOK _pexit, GitgudPexit
end
