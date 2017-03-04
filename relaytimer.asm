; relaytimer.asm
; 03.03.2017 T Schaer
; A 6-18hr timer with setting knob and status indicators
; 00: Get TIMER1 interrupt working.
;     Bar graph counts up with every LED being 1/8th of the Timeout Value
;     The "next" LED will blink to show counting progress. Works.
; 01: Switch to using the 16x16 divide from AVR200
; 02: Move display management out of ISR. With confusing results?
; 03: Ditch ISRs, use a polling loop. Oddly enough, this is reliable :-/
; 04: Change load values to correspond to 500ms; handle seconds counting &
;     expiry. Works.
; 05: Update the bar graph display, without blinking. Works.
; 06: Blink the topmost LED. Switch halves when LED is on & off
; 07: Add the 8th LED on RC4; fix expiry logic to allow 16-bit elapsed times
;     Doesn't work :-(
; 08: Try again by comparing Timeout to Elapsed for equality using XOR
;     Fix bug where ElapsedHI was always zero :-/ NOW it works
;     Also limit LED_no to be 7; it will go over when Timeout is not a multiple
;     of 8, causing Chunk to be truncated, allowing LED_no to go to 8, which
;     when "blinked" with LED_no+1, will run off the display (also crash LED_on)
; 09: Get ADC going, change Timeout & recompute Chunk. Remember to kill noise on
;     the ADC input with cap to ground. Works!
; 10: Timeout = ADC * 10. Seems to work...
; 11: Shift ADC right one, Timeout = ADC * 84 + 21600 & cross fingers
;     Aha oops, make Chunk 16 bits. Rolls over properly @ 16hrs!!
; 12: Move all the end-of-cycle stuff into the first half, test with hardcoded
;     values of InputHI:InputLO to verify timing behaviour (8 hrs, 12 hrs)
; 13: RA3 = "Start at Zero" button (enable Master Clear Reset function)
;     Put back to adjustable timeouts. Go over comments.
; 14: Changed LED assignment due to As-Built simplification (see LED_on)
; 15: Clean up.
;     - Remove unused variables
;     - Rename div16u to DIV16U
;     - Rename LED_no to Bars ('No' is such a negative word :^) )
;     - ##BUG discovered in expiry code, fix in next version
;     - Make TIMER1 reload value a named constant (RELOADH:L)
; 16: Fix expiry code. Since moving the knob may produce a timeout value that
;     is LESS than the already elapsed time, Elapsed == Timeout is replaced
;     by Elapsed >= Timeout, so the timer fires immediately

            list    p=16F688        ; processor type, do not remove
            __CONFIG 0x30F4         ; External MCLR, INTOSC

; Constants
RELOADH     EQU     0x85            ; TIMER1 reload value = 34285 (0x85ED)
RELOADL     EQU     0xED

; BANK0 Registers (All)
INDF        EQU     0x00            ; Indirect file register
TMR0        EQU     0x01
PCL         EQU     0x02            ; Program Counter Lo
STATUS      EQU     0x03            ; CPU status register
FSR         EQU     0x04            ; Indirect address register
PORTA       EQU     0x05
PORTC       EQU     0x07
PCLATH      EQU     0x0A
INTCON      EQU     0x0B
PIR1        EQU     0x0C            ; Peripheral status register
TMR1L       EQU     0x0E
TMR1H       EQU     0x0F
T1CON       EQU     0x10
BAUDCTL     EQU     0x11
SPBRGH      EQU     0x12
SPBRG       EQU     0x13
RCREG       EQU     0x14
TXREG       EQU     0x15
TXSTA       EQU     0x16
RCSTA       EQU     0x17
WDTCON      EQU     0x18
CMCON0      EQU     0x19
CMCON1      EQU     0x1A
ADRESH      EQU     0x1E
ADCON0      EQU     0x1F

; BANK1 Registers (No duplicates from BANK0)
OPTION_REG  EQU     0x81
TRISA       EQU     0x85            ; Data direction register PORT A
TRISC       EQU     0x87            ; Data direction register PORT C
PIE1        EQU     0x8C
OSCCON      EQU     0x8F            ; Internal oscillator config
OSCTUNE     EQU     0x90
ANSEL       EQU     0x91            ; A to D input pin enable
WPUA        EQU     0x95
IOCA        EQU     0x96
EEDATH      EQU     0x97
EEADRH      EQU     0x98
VRCON       EQU     0x99
EEDAT       EQU     0x9A
EEADR       EQU     0x9B
EECON1      EQU     0x9C
EECON2      EQU     0x9D
ADRESL      EQU     0x9E
ADCON1      EQU     0x9F

; Variables
; MUL16X8
A           EQU     0x20
BL          EQU     0x21
BH          EQU     0x22
R1          EQU     0x23
R2          EQU     0x24
R3          EQU     0x25
; DIV16U
NL          EQU     0x27
NH          EQU     0x28
DL          EQU     0x29
DH          EQU     0x2A
QL          EQU     0x2B
QH          EQU     0x2C
RL          EQU     0x2E
RH          EQU     0x2F
divstep     EQU     0x30
; MISC
Bars        EQU     0x72
ElapsedLO   EQU     0x73
ElapsedHI   EQU     0x74
TimeoutLO   EQU     0x75
TimeoutHI   EQU     0x76
InputLO     EQU     0x77
InputHI     EQU     0x78
ChunkLo     EQU     0x79
ChunkHi     EQU     0x7A


; Reset Vector
            ORG     0x000
            CLRF    STATUS
            GOTO    init

; Interrupt Vector
            ORG     0x004
ISR         NOP
            RETFIE

; PROGRAM STARTS HERE
; Bank is always in BANK0. Accesses to BANK1 always restore BANK0.
init        ; Set up CPU clock
            MOVLW   0x51            ; Fosc = 2MHz (CPU clock = Fosc/4 = 500kHz)
            BSF     STATUS,5        ; Bank 1
            MOVWF   OSCCON
            BCF     STATUS,5

            ; Common port configuration
            MOVLW   0x07            ; Turn off comparators
            MOVWF   CMCON0
            MOVLW   0x40            ; RC2/AN6 is analog input
            BSF     STATUS,5        ; Bank 1
            MOVWF   ANSEL
            BCF     STATUS,5

            ; Set up Port A
            CLRF    PORTA
            MOVLW   0x08            ; RA3 is an input
            BSF     STATUS,5        ; Bank 1
            MOVWF   TRISA
            BCF     STATUS,5

            ; Set up Port C
            CLRF    PORTC
            MOVLW   0x04            ; RC2 is an input
            BSF     STATUS,5        ; Bank 1
            MOVWF   TRISC
            BCF     STATUS,5

            ; Set up ADC
            MOVLW   0x40            ; ADC clock = Fosc/4 = 500kHz
            BSF     STATUS,5        ; Bank 1
            MOVWF   ADCON1
            BCF     STATUS,5
            MOVLW   0x99            ; Right justify, Vcc, AD6, ADC Enabled
            MOVWF   ADCON0

            ; Application setup
            CLRF    ElapsedLO
            CLRF    ElapsedHI
	    
	    ; Set up Timer 1
            MOVLW   0x34            ; Timer 1 = Fosc/4 + /8 prescaler = 62.5kHz
            MOVWF   T1CON

; Main loop
main        ; First half
            BCF     PIR1,0          ; Clear TIMR1F
            BCF     T1CON,0         ; Reload counter
            MOVLW   RELOADL
            MOVWF   TMR1L
            MOVLW   RELOADH
            MOVWF   TMR1H
            BSF     T1CON,0         ; Counter is running
            ; Read Timeout from Potentiometer 
            BSF     ADCON0,1        ; Start conversion
            BTFSC   ADCON0,1
            GOTO    $-1
            MOVF    ADRESH,W        ; Input = ADC
            MOVWF   InputHI
            BSF     STATUS,5
            MOVF    ADRESL,W
            BCF     STATUS,5
            MOVWF   InputLO         ; Input = Input/2 (noise mitigation)
            RRF     InputHI,F
            RRF     InputLO,F
            MOVF    InputLO,W       ; Timeout = Input * 84 (0x54)
            MOVWF   BL
            MOVF    InputHI,W
            MOVWF   BH
            MOVLW   0x54
            MOVWF   A
            CALL    MUL16X8
            MOVF    R1,W
            MOVWF   TimeoutLO
            MOVF    R2,W
            MOVWF   TimeoutHI
            MOVLW   0x60            ; Timeout = Timeout + 21600 (0x5460)
            ADDWF   TimeoutLO,F 
            BTFSC   STATUS,0
            INCF    TimeoutHI,F
            MOVLW   0x54
            ADDWF   TimeoutHI,F
            ; Update Chunk
            MOVF    TimeoutLO,W     ; Chunk = Timeout / 8
            MOVWF   NL
            MOVF    TimeoutHI,W
            MOVWF   NH
            MOVLW   0x08
            MOVWF   DL
            MOVLW   0x00
            MOVWF   DH
            CALL    DIV16U
            MOVF    QL, W
            MOVWF   ChunkLo
            MOVF    QH, W
            MOVWF   ChunkHi
            ; Update Bars
            MOVF    ElapsedLO,W     ; Bars = Elapsed / Chunk
            MOVWF   NL
            MOVF    ElapsedHI,W
            MOVWF   NH
            MOVF    ChunkLo,W
            MOVWF   DL
            MOVF    ChunkHi,W
            MOVWF   DH
            CALL    DIV16U
            MOVF    QL,W            ; IF Bars > 7 THEN Bars = 7
            ADDLW   .248            ; -8 in 2's comp
            BTFSS   STATUS,0
            GOTO    main_y
            MOVLW   0x07
            GOTO    main_z
main_y      MOVF    QL,W
            ; Update bar graph
main_z      MOVWF   Bars
            CALL    LED_on
            ; End of First Half tasks
            BTFSS   PIR1,0          ; Wait for timer to expire
            GOTO    $-1

            ; Second half
            BCF     PIR1,0          ; Clear TIMR1F
            BCF     T1CON,0         ; Reload counter with 34285
            MOVLW   RELOADL
            MOVWF   TMR1L
            MOVLW   RELOADH
            MOVWF   TMR1H
            BSF     T1CON,0         ; Counter is running
            ; Update bar graph
            INCF    Bars,F
            CALL    LED_on
            ; End of Second Half tasks
            BTFSS   PIR1,0          ; Wait for timer to expire
            GOTO    $-1

            ; End-of-Cycle tasks
            ; Update elapsed time
            INCF    ElapsedLO,F
            BTFSC   STATUS,2
            INCF    ElapsedHI,F
            ; Handle expiry (Elapsed >= Timeout)
	    ; Port C.3 will be high for one full cycle
            BCF     PORTC,3
	    MOVF    TimeoutHI, W
	    SUBWF   ElapsedHI, W
	    BTFSS   STATUS,0
	    GOTO    main_x
	    MOVF    TimeoutLO, W
	    SUBWF   ElapsedLO, W
	    BTFSS   STATUS,0
	    GOTO    main_x
	    BSF	    PORTC,3
	    CLRF    ElapsedLO
	    CLRF    ElapsedHI
main_x      GOTO    main

; Subroutines
; LED_off_all : turn off all LEDs
LED_off_all BCF     PORTC,4
            BCF     PORTA,4
            BCF     PORTA,5
            BCF     PORTC,1
            BCF     PORTC,0
            BCF     PORTA,2
            BCF     PORTA,1
            BCF     PORTA,0
            RETURN

; LED_on : Display Bars as a bar graph. Numbers go from 0 to 8
LED_on      CALL    LED_off_all
            MOVF    Bars,W          ; Jump offset = 8 - Bars
            SUBLW   0x08
            ADDWF   PCL,F
LED_on_all  BSF     PORTC,4         ; ********
            BSF     PORTA,4         ; *******
            BSF     PORTA,5         ; ******
            BSF     PORTC,1         ; *****
            BSF     PORTC,0         ; ****
            BSF     PORTA,2         ; ***
            BSF     PORTA,1         ; **
            BSF     PORTA,0         ; *
            NOP                     ;
            RETURN

; MUL16X8 : (h_ttp://www.piclist.com/techref/microchip/math/mul/m16x8mds2.htm)
; R3:R2:R1 = A*BH:BL
MUL16X8     CLRF    R3
            CLRF    R2
            CLRF    R1
            BSF     R1,7
M1          RRF     A,F
            BTFSS   STATUS,0        ; SKPC
            GOTO    M2
            MOVFW   BL
            ADDWF   R2,F
            MOVFW   BH
            BTFSC   STATUS,0        ; SKPNC
            INCFSZ  BH,W
            ADDWF   R3,F
M2          RRF     R3,F
            RRF     R2,F
            RRF     R1,F
            BTFSS   STATUS,0        ; SKPC
            GOTO    M1
            RETURN

; DIV16U : Adapted from AVR DIV16S (App Note AVR200)
; Both operands are assumed to be positive, tracking of what sign the
; quotient shall have is done before calling this routine.
; Write numerator to NH:NL, write denominator to DH:DL
; Quotient is in QH:QL, remainder is in RH:RL
DIV16U      CLRF    RL              ; Initialize
            CLRF    RH
            MOVLW   .17
            MOVWF   divstep
            BCF     STATUS,0
DIV16U_3    RLF     NL,1            ; Division loop
            RLF     NH,1
            DECFSZ  divstep,1
            GOTO    DIV16U_5
            MOVF    NL,0            ; Exit & clean up
            MOVWF   QL
            MOVF    NH,0
            MOVWF   QH
DIV16U_4    RETURN                  ; Done
DIV16U_5    RLF     RL,1
            RLF     RH,1
            MOVF    DL,0            ; R = R - D
            SUBWF   RL,1
            MOVF    DH,0
            BTFSS   STATUS,0
            INCF    DH,0
            SUBWF   RH,1
            BTFSC   STATUS,0        ; Carry = 0 -> borrow occurred, undo subtraction
            GOTO    DIV16U_6
            MOVF    DL,0            ; R = R + D
            ADDWF   RL,1
            MOVF    DH,0
            BTFSC   STATUS,0
            INCF    DH,0
            ADDWF   RH,1
            BCF     STATUS,0
            GOTO    DIV16U_3
DIV16U_6    BSF     STATUS,0
            GOTO    DIV16U_3

            END