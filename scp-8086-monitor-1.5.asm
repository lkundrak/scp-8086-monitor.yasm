CPU 8086

; Seattle Computer Products 8086 Monitor version 1.5  6-10-82.
;   by Tim Paterson
; This software is not copyrighted.

; Ported to YASM by Lubomir Rintel <lkundrak@v3.sk> 4-29-2024

; To select a disk boot, set one of the following equates
; to 1, the rest to 0.

%define SCP		1	;1 for SCP, 0 for others.
%define CROMEMCO4FDC	0	;Cromemco 4FDC?
%define CROMEMCO16FDC	0	;Cromemco 16FDC?
%define NORTHSTARSD	0	;North Star single density?
%define TARBELLSD	0	;Tarbell SD controller or DD controller SD only
%define TARBELLDD	0	;Tarbell DD controller SD or DD?
%define OTHER		0	;User-defined disk

PUTBASE:EQU	100H
LOAD:	EQU	200H

SEGMENT ENTRY START=07F0h
	JMP	0FF80H:0	;Power-on jump to monitor

;Baud Rate Table. The 9513 divides 2MHz by these values.
;They are for 9600, 1200, 300, 150, 110 baud

BAUD:	DW	13,104,416,832,1144

        ALIGN   16,DB 0FFH

SEGMENT RAM NOBITS VSTART=100h  ;RAM area base address

;System Equates

BASE:	EQU	0F0H		;CPU Support base port address
STAT:	EQU	BASE+7		;UART status port
DATA:	EQU	BASE+6		;UART data port
DAV:	EQU	2		;UART data available bit
TBMT:	EQU	1		;UART transmitter ready bit
BUFLEN:	EQU	80		;Maximum length of line input buffer
BPMAX:	EQU	10		;Maximum number of breakpoints
BPLEN:	EQU	BPMAX+BPMAX	;Length of breakpoint table
REGTABLEN:EQU	14		;Number of registers
SEGDIF:	EQU	800H		;-0FF800H (ROM address)
PROMPT:	EQU	">"
CAN:	EQU	"@"

;RAM area.

BRKCNT:	DW	?		;Number of breakpoints
TCOUNT:	DW	?		;Number of steps to trace
BPTAB:	TIMES	BPLEN DB ?	;Breakpoint table
LINEBUF:TIMES	BUFLEN+1 DB ?	;Line input buffer
	ALIGNB	2
	TIMES	50 DB ?		;Working stack area
STACK:

;Register save area

AXSAVE:	DW	?
BXSAVE:	DW	?
CXSAVE:	DW	?
DXSAVE:	DW	?
SPSAVE:	DW	?
BPSAVE:	DW	?
SISAVE:	DW	?
DISAVE:	DW	?
DSSAVE:	DW	?
ESSAVE:	DW	?
RSTACK:		;Stack set here so registers can be saved by pushing
SSSAVE:	DW	?
CSSAVE:	DW	?
IPSAVE:	DW	?
FSAVE:	DW	?

;Start of Monitor code

SEGMENT TEXT VSTART=0 START=0

;One-time initialization

	CLD
	XOR	AX,AX
	MOV	SS,AX
	MOV	DS,AX
	MOV	ES,AX
	MOV	DI,AXSAVE
	MOV	CX,14
	REP
	STOSW			;Set register images to zero
	OR	BYTE [FSAVE+1],2	;Enable interrupts
	MOV	CL,4
	MOV	AL,40H
	MOV	DI,DSSAVE
	REP
	STOSW			;Set segment reg. images to 40H
	MOV	BYTE [SPSAVE+1],0CH	;Set user stack to 400H+0C00H
	MOV	SP,STACK
;Prepare 9513
	MOV	AL,17H
	OUT	BASE+5,AL	;Select Master Mode register
	MOV	AL,0F3H
	OUT	BASE+4,AL	;Low byte of Master Mode
	MOV	AX,584H		;Output 84H to BASE+4
	OUT	BASE+4,AX	;and 05H to BASE+5
;Master Mode now set to 84F3H:
;	Scaler set to BCD division
;	Enable data pointer increment
;	8-bit data bus
;	FOUT=100Hz, dividing F5 by 4 (F5=4MHz/10000)
;	Both alarm comparators disabled
;	Time-of-day enabled
;Counter 5 selected

;Initialize loop. Ports BASE through BASE+7 are initialized
;from table. Each table entry has number of bytes followed by
;data.

	MOV	SI,INITTABLE	;Initialization table
	MOV	DX,BASE		;DX has (variable) port no.
INITPORT:
	CS
	LODSB			;Get byte count
	MOV	CL,AL
	JCXZ	NEXTPORT	;No init. for some ports
INITBYTE:
	CS
	LODSB			;Get init. data
	OUT	DX,AL		;Send to port
	LOOP	INITBYTE	;As many bytes as required
NEXTPORT:
	INC	DX		;Prepare for next port
	CMP	DL,BASE+8	;Check against limit
	JNZ	INITPORT

;Initialization complete except for determining baud rate.
;Both 8259As are ready to accept interrupts, the 9513 is
;providing 19.2k baud X 16 to the 8251A which is set for
;16X clock and one stop bit.

	CALL	CHECKB		;Check for correct baud rate
;CHECKB does not return if baud rate is correct

;Intial baud rate (19.2k) was wrong, so run auto-baud routine

INITBAUD:
	MOV	SI,BAUD
;First set up 9513 for slower baud rates (<=9600).
;Counter 5 mode register has already been selected.
	MOV	AX,0E823H	;Output 23H to BASE+4
	OUT	BASE+4,AX	;and 0E8H to BASE+5
;23H to BASE+4 sets lower half of Counter 5 mode register.
;Reload from Load, count down repetively in binary, 
;toggle output.
;0E8H to BASE+5 disables data pointer sequencing

	MOV	AL,0DH
	OUT	BASE+5,AL	;Select Counter 5 load reg.
INITB:
	CS
	LODSW			;Get divisor
	OUT	BASE+4,AL	;Output low byte
	MOV	AL,AH
	OUT	BASE+4,AL	;Output high byte
	CALL	CHECKB		;Check if baud rate correct
	JMP	INITB		;Try next rate if not
CHECKB:
	CALL	CHIN		;First byte could be messed up
	CALL	CHIN		;Get carriage return
	CMP	AL,13		;Correct?
	JZ	MONITOR		;Don't return if correct
	RET			;Didn't get it yet

;Initialization complete, including baud rate.

MONITOR:
; Do auto boot if sense switch 0 is on.
	MOV	DI,LINEBUF
	MOV	BYTE [DI],13	;No breakpoints after boot
	IN	AL,BASE+0FH	;Sense switch port
	TEST	AL,1
	JZ	DOMON
	JMP	BOOT
DOMON:
	MOV	SI,HEADER
	CALL	PRINTMES
COMMAND:
;Re-establish initial conditions
	CLD
	XOR	AX,AX
	MOV	DS,AX
	MOV	ES,AX
	MOV	SP,STACK
	MOV	WORD [64H],CHINT	;Set UART interrupt vector
	MOV	WORD [66H],CS
	MOV	AL,PROMPT
	CALL	CHOUT
	CALL	INBUF		;Get command line
;From now and throughout command line processing, DI points
;to next character in command line to be processed.
	CALL	SCANB		;Scan off leading blanks
	JZ	COMMAND		;Null command?
	MOV	AL,[DI]		;AL=first non-blank character
;Prepare command letter for table lookup
	SUB	AL,"B"		;Low end range check
	JC	ERR1
	CMP	AL,"T"+1-"B"	;Upper end range check
	JNC	ERR1
	INC	DI
	SHL	AL,1		;Times two
	CBW			;Now a 16-bit quantity
	XCHG	BX,AX		;In BX we can address with it
	CS
	CALL	[BX+COMTAB]	;Execute command
	JMP	COMMAND		;Get next command
ERR1:	JMP	ERROR

;Get input line

INBUF:
	MOV	DI,LINEBUF	;Next empty buffer location
	XOR	CX,CX		;Character count
GETCH:
	CALL	CHIN		;Get input character
	CMP	AL,20H		;Check for control characters
	JC	CONTROL
	CMP	AL,7FH		;RUBOUT is a backspace
	JZ	BACKSP
	CALL	CHOUT		;Echo character
	CMP	AL,CAN		;Cancel line?
	JZ	KILL
	STOSB			;Put in input buffer
	INC	CX		;Bump character count
	CMP	CX,BUFLEN	;Buffer full?
	JBE	GETCH		;Drop in to backspace if full
BACKSP:
	JCXZ	GETCH		;Can't backspace over nothing
	DEC	DI		;Drop pointer
	DEC	CX		;and character count
	CALL	BACKUP		;Send physical backspace
	JMP	GETCH		;Get next char.
CONTROL:
	CMP	AL,8		;Check for backspace
	JZ	BACKSP
	CMP	AL,13		;Check for carriage return
	JNZ	GETCH		;Ignore all other control char.
	STOSB			;Put the car. ret. in buffer
	MOV	DI,LINEBUF	;Set up DI for command processing

;Output CR/LF sequence

CRLF:
	MOV	AL,13
	CALL	CHOUT
	MOV	AL,10
	JMP	CHOUT

;Cancel input line

KILL:
	CALL	CRLF
	JMP	COMMAND

;Character input routine

CHIN:
	CLI			;Poll, don't interrupt
	IN	AL,STAT
	TEST	AL,DAV
	JZ	CHIN		;Loop until ready
	IN	AL,DATA
	AND	AL,7FH		;Only 7 bits
	STI			;Interrupts OK now
	RET

;Physical backspace - blank, backspace, blank

BACKUP:
	MOV	SI,BACMES

;Print ASCII message. Last char has bit 7 set

PRINTMES:
	CS
	LODSB			;Get char to print
	CALL	CHOUT
	SHL	AL,1		;High bit set?
	JNC	PRINTMES
	RET

;Scan for parameters of a command

SCANP:
	CALL	SCANB		;Get first non-blank
	CMP	BYTE [DI],","	;One comma between params OK
	JNE	EOLCHK		;If not comma, we found param
	INC	DI		;Skip over comma

;Scan command line for next non-blank character

SCANB:
	MOV	AL," "
	PUSH	CX		;Don't disturb CX
	MOV	CL,-1		;but scan as many as necessary
	REPE
	SCASB
	DEC	DI		;Back up to first non-blank
	POP	CX
EOLCHK:
	CMP	BYTE [DI],13
	RET

;Print the 5-digit hex address of SI and DS

OUTSI:
	MOV	DX,DS		;Put DS where we can work with it
	MOV	AH,0		;Will become high bits of DS
	CALL	SHIFT4		;Shift DS four bits
	ADD	DX,SI		;Compute absolute address
	JMP	OUTADD		;Finish below

;Print 5-digit hex address of DI and ES
;Same as OUTSI above

OUTDI:
	MOV	DX,ES
	MOV	AH,0
	CALL	SHIFT4
	ADD	DX,DI
;Finish OUTSI here too
OUTADD:
	ADC	AH,0		;Add in carry to high bits
	CALL	HIDIG		;Output hex value in AH

;Print out 16-bit value in DX in hex

OUT16:
	MOV	AL,DH		;High-order byte first
	CALL	HEX
	MOV	AL,DL		;Then low-order byte

;Output byte in AL as two hex digits

HEX:
	MOV	AH,AL		;Save for second digit
;Shift high digit into low 4 bits
	PUSH	CX
	MOV	CL,4
	SHR	AL,CL
	POP	CX

	CALL	DIGIT		;Output first digit
HIDIG:
	MOV	AL,AH		;Now do digit saved in AH
DIGIT:
	AND	AL,0FH		;Mask to 4 bits
;Trick 6-byte hex conversion works on 8086 too.
	ADD	AL,90H
	DAA
	ADC	AL,40H
	DAA

;Console output of character in AL

CHOUT:
	PUSH	AX		;Character to output on stack
OUT1:
	IN	AL,STAT
	AND	AL,TBMT
	JZ	OUT1		;Wait until ready
	POP	AX
	OUT	DATA,AL
	RET

;Output one space

BLANK:
	MOV	AL," "
	JMP	CHOUT

;Output the number of blanks in CX

TAB:
	CALL	BLANK
	LOOP	TAB
	RET

;Command Table. Command letter indexes into table to get
;address of command. PERR prints error for no such command.

COMTAB:
	DW	BOOT		;B
	DW	PERR		;C
	DW	DUMP		;D
	DW	ENTER		;E
	DW	FILL		;F
	DW	GO		;G
	DW	PERR		;H
	DW	INPUT		;I
	DW	PERR		;J
	DW	PERR		;K
	DW	PERR		;L
	DW	MOVE		;M
	DW	PERR		;N
	DW	OUTPUT		;O
	DW	PERR		;P
	DW	PERR		;Q
	DW	REG		;R
	DW	SEARCH		;S
	DW	TRACE		;T

;Given 20-bit address in AH:DX, breaks it down to a segment
;number in AX and a displacement in DX. Displacement is 
;always zero except for least significant 4 bits.

GETSEG:
	MOV	AL,DL
	AND	AL,0FH		;AL has least significant 4 bits
	CALL	SHIFT4		;4-bit left shift of AH:DX
	MOV	DL,AL		;Restore lowest 4 bits
	MOV	AL,DH		;Low byte of segment number
	XOR	DH,DH		;Zero high byte of displacement
	RET

;Shift AH:DX left 4 bits

SHIFT4:
	SHL	DX,1
	RCL	AH,1	;1
	SHL	DX,1
	RCL	AH,1	;2
	SHL	DX,1
	RCL	AH,1	;3
	SHL	DX,1
	RCL	AH,1	;4
RET2:	RET

;RANGE - Looks for parameters defining an address range.
;The first parameter is a hex number of 5 or less digits
;which specifies the starting address. The second parameter
;may specify the ending address, or it may be preceded by
;"L" and specify a length (4 digits max), or it may be
;omitted and a length of 128 bytes is assumed. Returns with
;segment no. in AX and displacement (0-F) in DX.

RANGE:
	MOV	CX,5		;5 digits max
	CALL	GETHEX		;Get hex number
	PUSH	AX		;Save high 4 bits
	PUSH	DX		;Save low 16 bits
	CALL	SCANP		;Get to next parameter
	CMP	BYTE [DI],"L"	;Length indicator?
	JE	GETLEN
	MOV	DX,128		;Default length
	CALL	HEXIN		;Second parameter present?
	JC	RNGRET		;If not, use default
	MOV	CX,5		;5 hex digits
	CALL	GETHEX		;Get ending address
	MOV	CX,DX		;Low 16 bits of ending addr.
	POP	DX		;Low 16 bits of starting addr.
	POP	BX		;BH=hi 4 bits of start addr.
	SUB	CX,DX		;Compute range
	SBB	AH,BH		;Finish 20-bit subtract
	JNZ	RNGERR		;Range must be less than 64K
	XCHG	AX,BX		;AH=starting, BH=ending hi 4 bits
	INC	CX		;Range must include ending location
	JMP	RNGCHK		;Finish range testing and return
GETLEN:
	INC	DI		;Skip over "L" to length
	MOV	CX,4		;Length may have 4 digits
	CALL	GETHEX		;Get the range
RNGRET:
	MOV	CX,DX		;Length
	POP	DX		;Low 16 bits of starting addr.
	POP	AX		;AH=hi 4 bits of starting addr.

;RNGCHK verifies that the range lies entirely within one segment.
;CX=0 means count=10000H. Range is within one segment only if
;adding the low 4 bits of the starting address to the count is
;<=10000H, because segments can start only on 16-byte boundaries.

RNGCHK:
	MOV	BX,DX		;Low 16 bits of start addr.
	AND	BX,0FH		;Low 4 bits of starting addr.
	JCXZ	MAXRNG		;If count=10000H then BX must be 0
	ADD	BX,CX		;Must be <=10000H
	JNC	GETSEG		;OK if strictly <
MAXRNG:
;If here because of JCXZ MAXRNG, we are testing if low 4 bits
;(in BX) are zero. If we dropped straight in, we are testing
;for BX+CX=10000H (=0). Either way, zero flag set means 
;withing range.
	JZ	GETSEG
RNGERR:
	MOV	AX,4700H+"R"	;RG ERROR
	JMP	ERR

;Dump an area of memory in both hex and ASCII

DUMP:
	CALL	RANGE		;Get range to dump
	PUSH	AX		;Save segment
	CALL	GETEOL		;Check for errors
	POP	DS		;Set segment
	MOV	SI,DX		;SI has displacement in segment
ROW:
	CALL	OUTSI		;Print address at start of line
	PUSH	SI		;Save address for ASCII dump
BYTE0:
	CALL	BLANK		;Space between bytes
BYTE1:
	LODSB			;Get byte to dump
	CALL	HEX		;and display it
	POP	DX		;DX has start addr. for ASCII dump
	DEC	CX		;Drop loop count
	JZ	ASCII		;If through do ASCII dump
	MOV	AX,SI
	TEST	AL,0FH		;On 16-byte boundary?
	JZ	ENDROW
	PUSH	DX		;Didn't need ASCII addr. yet
	TEST	AL,7		;On 8-byte boundary?
	JNZ	BYTE0
	MOV	AL,"-"		;Mark every 8 bytes
	CALL	CHOUT
	JMP	BYTE1
ENDROW:
	CALL	ASCII		;Show it in ASCII
	JMP	ROW		;Loop until count is zero
ASCII:
	PUSH	CX		;Save byte count
	MOV	AX,SI		;Current dump address
	MOV	SI,DX		;ASCII dump address
	SUB	AX,DX		;AX=length of ASCII dump
;Compute tab length. ASCII dump always appears on right side
;screen regardless of how many bytes were dumped. Figure 3
;characters for each byte dumped and subtract from 51, which
;allows a minimum of 3 blanks after the last byte dumped.
	MOV	BX,AX
	SHL	AX,1		;Length times 2
	ADD	AX,BX		;Length times 3
	MOV	CX,51
	SUB	CX,AX		;Amount to tab in CX
	CALL	TAB
	MOV	CX,BX		;ASCII dump length back in CX
ASCDMP:
	LODSB			;Get ASCII byte to dump
	AND	AL,7FH		;ASCII uses 7 bits
	CMP	AL,7FH		;Don't try to print RUBOUT
	JZ	NOPRT
	CMP	AL," "		;Check for control characters
	JNC	PRIN
NOPRT:
	MOV	AL,"."		;If unprintable character
PRIN:
	CALL	CHOUT		;Print ASCII character
	LOOP	ASCDMP		;CX times
	POP	CX		;Restore overall dump length
	JMP	CRLF		;Print CR/LF and return

;Block move one area of memory to another. Overlapping moves
;are performed correctly, i.e., so that a source byte is not
;overwritten until after it has been moved.

MOVE:
	CALL	RANGE		;Get range of source area
	PUSH	CX		;Save length
	PUSH	AX		;Save segment
	MOV	SI,DX		;Set source displacement
	MOV	CX,5		;Allow 5 digits
	CALL	GETHEX		;in destination address
	CALL	GETEOL		;Check for errors
	CALL	GETSEG		;Convert dest. to seg/disp
	MOV	DI,DX		;Set dest. displacement
	POP	BX		;Source segment
	MOV	DS,BX
	MOV	ES,AX		;Destination segment
	POP	CX		;Length
	CMP	DI,SI		;Check direction of move
	SBB	AX,BX		;Extend the CMP to 32 bits
	JB	COPYLIST	;Move forward into lower mem.
;Otherwise, move backward. Figure end of source and destination
;areas and flip direction flag.
	DEC	CX
	ADD	SI,CX		;End of source area
	ADD	DI,CX		;End of destination area
	STD			;Reverse direction
	INC	CX
COPYLIST:
	MOVSB	;Do at least 1 - Range is 1-10000H not 0-FFFFH
	DEC	CX
	REP
	MOVSB			;Block move
	RET

;Fill an area of memory with a list values. If the list
;is bigger than the area, don't use the whole list. If the
;list is smaller, repeat it as many times as necessary.

FILL:
	CALL	RANGE		;Get range to fill
	PUSH	CX		;Save length
	PUSH	AX		;Save segment number
	PUSH	DX		;Save displacement
	CALL	LIST		;Get list of values to fill with
	POP	DI		;Displacement in segment
	POP	ES		;Segment
	POP	CX		;Length
	CMP	BX,CX		;BX is length of fill list
	MOV	SI,LINEBUF	;List is in line buffer
	JCXZ	BIGRNG
	JAE	COPYLIST	;If list is big, copy part of it
BIGRNG:
	SUB	CX,BX		;How much bigger is area than list?
	XCHG	CX,BX		;CX=length of list
	PUSH	DI		;Save starting addr. of area
	REP
	MOVSB			;Move list into area
	POP	SI
;The list has been copied into the beginning of the 
;specified area of memory. SI is the first address
;of that area, DI is the end of the copy of the list
;plus one, which is where the list will begin to repeat.
;All we need to do now is copy [SI] to [DI] until the
;end of the memory area is reached. This will cause the
;list to repeat as many times as necessary.
	MOV	CX,BX		;Length of area minus list
	PUSH	ES		;Different index register
	POP	DS		;requires different segment reg.
	JMP	COPYLIST	;Do the block move

;Search a specified area of memory for given list of bytes.
;Print address of first byte of each match.

SEARCH:
	CALL	RANGE		;Get area to be searched
	PUSH	CX		;Save count
	PUSH	AX		;Save segment number
	PUSH	DX		;Save displacement
	CALL	LIST		;Get search list
	DEC	BX		;No. of bytes in list-1
	POP	DI		;Displacement within segment
	POP	ES		;Segment
	POP	CX		;Length to be searched
	SUB	CX,BX		;  minus length of list
SCAN:
	MOV	SI,LINEBUF	;List kept in line buffer
	LODSB			;Bring first byte into AL
DOSCAN:
	SCASB			;Search for first byte
	LOOPNE	DOSCAN		;Do at least once by using LOOP
	JNZ	RET1		;Exit if not found
	PUSH	BX		;Length of list minus 1
	XCHG	BX,CX
	PUSH	DI		;Will resume search here
	REPE
	CMPB			;Compare rest of string
	MOV	CX,BX		;Area length back in CX
	POP	DI		;Next search location
	POP	BX		;Restore list length
	JNZ	TST		;Continue search if no match
	DEC	DI		;Match address
	CALL	OUTDI		;Print it
	INC	DI		;Restore search address
	CALL	CRLF
TST:
	JCXZ	RET1
	JMP	SCAN		;Look for next occurrence

;Get the next parameter, which must be a hex number.
;CX is maximum number of digits the number may have.

GETHEX:
	CALL	SCANP		;Scan to next parameter
GETHEX1:
	XOR	DX,DX		;Initialize the number
	MOV	AH,DH
	CALL	HEXIN		;Get a hex digit
	JC	ERROR		;Must be one valid digit
	MOV	DL,AL		;First 4 bits in position
GETLP:
	INC	DI		;Next char in buffer
	DEC	CX		;Digit count
	CALL	HEXIN		;Get another hex digit?
	JC	RET1		;All done if no more digits
	JCXZ	ERROR		;Too many digits?
	CALL	SHIFT4		;Multiply by 16
	OR	DL,AL		;and combine new digit
	JMP	GETLP		;Get more digits

;Check if next character in the input buffer is a hex digit
;and convert it to binary if it is. Carry set if not.

HEXIN:
	MOV	AL,[DI]

;Check if AL has a hex digit and convert it to binary if it
;is. Carry set if not.

HEXCHK:
	SUB	AL,"0"		;Kill ASCII numeric bias
	JC	RET1
	CMP	AL,10
	CMC
	JNC	RET1		;OK if 0-9
	SUB	AL,7		;Kill A-F bias
	CMP	AL,10
	JC	RET1
	CMP	AL,16
	CMC
RET1:	RET

;Process one parameter when a list of bytes is
;required. Carry set if parameter bad. Called by LIST

LISTITEM:
	CALL	SCANP		;Scan to parameter
	CALL	HEXIN		;Is it in hex?
	JC	STRINGCHK	;If not, could be a string
	MOV	CX,2		;Only 2 hex digits for bytes
	CALL	GETHEX		;Get the byte value
	MOV	[BX],DL		;Add to list
	INC	BX
GRET:	CLC			;Parameter was OK
	RET
STRINGCHK:
	MOV	AL,[DI]		;Get first character of param
	CMP	AL,"'"		;String?
	JZ	STRING
	CMP	AL,'"'		;Either quote is all right
	JZ	STRING
	STC			;Not string, not hex - bad
	RET
STRING:
	MOV	AH,AL		;Save for closing quote
	INC	DI
STRNGLP:
	MOV	AL,[DI]		;Next char of string
	INC	DI
	CMP	AL,13		;Check for end of line
	JZ	ERROR		;Must find a close quote
	CMP	AL,AH		;Check for close quote
	JNZ	STOSTRG		;Add new character to list
	CMP	AH,[DI]		;Two quotes in a row?
	JNZ	GRET		;If not, we're done
	INC	DI		;Yes - skip second one
STOSTRG:
	MOV	[BX],AL		;Put new char in list
	INC	BX
	JMP	STRNGLP		;Get more characters

;Get a byte list for ENTER, FILL or SEARCH. Accepts any number
;of 2-digit hex values or character strings in either single
;(') or double (") quotes.

LIST:
	MOV	BX,LINEBUF	;Put byte list in the line buffer
LISTLP:
	CALL	LISTITEM	;Process a parameter
	JNC	LISTLP		;If OK, try for more
	SUB	BX,LINEBUF	;BX now has no. of bytes in list
	JZ	ERROR		;List must not be empty

;Make sure there is nothing more on the line except for
;blanks and carriage return. If there is, it is an
;unrecognized parameter and an error.

GETEOL:
	CALL	SCANB		;Skip blanks
	JNZ	ERROR		;Better be a RETURN
	RET

;Command error. DI has been incremented beyond the
;command letter so it must decremented for the
;error pointer to work.

PERR:
	DEC	DI

;Syntax error. DI points to character in the input buffer
;which caused error. By subtracting from start of buffer,
;we will know how far to tab over to appear directly below
;it on the terminal. Then print "^ Error".

ERROR:
	SUB	DI,LINEBUF-1	;How many char processed so far?
	MOV	CX,DI		;Parameter for TAB in CX
	CALL	TAB		;Directly below bad char
	MOV	SI,SYNERR	;Error message

;Print error message and abort to command level

PRINT:
	CALL	PRINTMES
	JMP	COMMAND

;Short form of ENTER command. A list of values from the
;command line are put into memory without using normal
;ENTER mode.

GETLIST:
	CALL	LIST		;Get the bytes to enter
	POP	DI		;Displacement within segment
	POP	ES		;Segment to enter into
	MOV	SI,LINEBUF	;List of bytes is in line buffer
	MOV	CX,BX		;Count of bytes
	REP
	MOVSB			;Enter that byte list
	RET

;Enter values into memory at a specified address. If the
;line contains nothing but the address we go into "enter
;mode", where the address and its current value are printed
;and the user may change it if desired. To change, type in
;new value in hex. Backspace works to correct errors. If
;an illegal hex digit or too many digits are typed, the
;bell is sounded but it is otherwise ignored. To go to the
;next byte (with or without change), hit space bar. To
;back up to a previous address, type "-". On
;every 8-byte boundary a new line is started and the address
;is printed. To terminate command, type carriage return.
;   Alternatively, the list of bytes to be entered may be
;included on the original command line immediately following
;the address. This is in regular LIST format so any number
;of hex values or strings in quotes may be entered.

ENTER:
	MOV	CX,5		;5 digits in address
	CALL	GETHEX		;Get ENTER address
	CALL	GETSEG		;Convert to seg/disp format
;Adjust segment and displacement so we are in the middle
;of the segment instead of the very bottom. This allows
;backing up a long way.
	SUB	AH,8		;Adjust segment 32K down
	ADD	DH,80H		; and displacement 32K up
	PUSH	AX		;Save for later
	PUSH	DX
	CALL	SCANB		;Any more parameters?
	JNZ	GETLIST		;If not end-of-line get list
	POP	DI		;Displacement of ENTER
	POP	ES		;Segment
GETROW:
	CALL	OUTDI		;Print address of entry
	CALL	BLANK		;Leave a space
GETBYTE:
	ES
	MOV	AL,[DI]		;Get current value
	CALL	HEX		;And display it
	MOV	AL,"."
	CALL	CHOUT		;Prompt for new value
	MOV	CX,2		;Max of 2 digits in new value
	MOV	DX,0		;Intial new value
GETDIG:
	CALL	CHIN		;Get digit from user
	MOV	AH,AL		;Save
	CALL	HEXCHK		;Hex digit?
	XCHG	AH,AL		;Need original for echo
	JC	NOHEX		;If not, try special command
	CALL	CHOUT		;Echo to console
	MOV	DH,DL		;Rotate new value
	MOV	DL,AH		;And include new digit
	LOOP	GETDIG		;At most 2 digits
;We have two digits, so all we will accept now is a command.
WT:
	CALL	CHIN		;Get command character
NOHEX:
	CMP	AL,8		;Backspace
	JZ	BS
	CMP	AL,7FH		;RUBOUT
	JZ	BS
	CMP	AL,"-"		;Back up to previous address
	JZ	PREV
	CMP	AL,13		;All done with command?
	JZ	EOL
	CMP	AL," "		;Go to next address
	JZ	NEXT
;If we got here, character was invalid. Sound bell.
	MOV	AL,7
	CALL	CHOUT
	JCXZ	WT		;CX=0 means no more digits
	JMP	GETDIG		;Don't have 2 digits yet
BS:
	CMP	CL,2		;CX=2 means nothing typed yet
	JZ	GETDIG		;Can't back up over nothing
	INC	CL		;Accept one more character
	MOV	DL,DH		;Rotate out last digit
	MOV	DH,CH		;Zero this digit
	CALL	BACKUP		;Physical backspace
	JMP	GETDIG		;Get more digits

;If new value has been entered, convert it to binary and
;put into memory. Always bump pointer to next location

STORE:
	CMP	CL,2		;CX=2 means nothing typed yet
	JZ	NOSTO		;So no new value to store
;Rotate DH left 4 bits to combine with DL and make a byte value
	PUSH	CX
	MOV	CL,4
	SHL	DH,CL
	POP	CX
	OR	DL,DH		;Hex is now converted to binary
	ES
	MOV	[DI],DL		;Store new value
NOSTO:
	INC	DI		;Prepare for next location
	RET
EOL:
	CALL	STORE		;Enter the new value
	JMP	CRLF		;CR/LF and terminate
NEXT:
	CALL	STORE		;Enter new value
	INC	CX		;Leave a space plus two for
	INC	CX		;  each digit not entered
	CALL	TAB
	MOV	AX,DI		;Next memory address
	AND	AL,7		;Check for 8-byte boundary
	JNZ	GETBYTE		;Take 8 per line
NEWROW:
	CALL	CRLF		;Terminate line
	JMP	GETROW		;Print address on new line
PREV:
	CALL	STORE		;Enter the new value
;DI has been bumped to next byte. Drop it 2 to go to previous addr
	DEC	DI
	DEC	DI
	JMP	NEWROW		;Terminate line after backing up

;Perform register dump if no parameters or set register if a
;register designation is a parameter.

REG:
	CALL	SCANP
	JZ	DISPREG
	MOV	DL,[DI]
	INC	DI
	MOV	DH,[DI]
	CMP	DH,13
	JZ	FLAG
	INC	DI
	CALL	GETEOL
	CMP	DH," "
	JZ	FLAG
	MOV	DI,REGTAB
	XCHG	AX,DX
	PUSH	CS
	POP	ES
	MOV	CX,REGTABLEN
	REPNZ
	SCASW
	JNZ	BADREG
	OR	CX,CX
	JNZ	NOTPC
	DEC	DI
	DEC	DI
	CS
	MOV	AX,[DI-2]
NOTPC:
	CALL	CHOUT
	MOV	AL,AH
	CALL	CHOUT
	CALL	BLANK
	PUSH	DS
	POP	ES
	LEA	BX,[DI+REGDIF-2]
	MOV	DX,[BX]
	CALL	OUT16
	CALL	CRLF
	MOV	AL,":"
	CALL	CHOUT
	CALL	INBUF
	CALL	SCANB
	JZ	RET3
	MOV	CX,4
	CALL	GETHEX1
	CALL	GETEOL
	MOV	[BX],DX
RET3:	RET
BADREG:
	MOV	AX,5200H+"B"	;BR ERROR
	JMP	ERR
DISPREG:
	MOV	SI,REGTAB
	MOV	BX,AXSAVE
	MOV	CX,8
	CALL	DISPREGLINE
	CALL	CRLF
	MOV	CX,5
	CALL	DISPREGLINE
	CALL	BLANK
	CALL	DISPFLAGS
	JMP	CRLF
FLAG:
	CMP	DL,"F"
	JNZ	BADREG
	CALL	DISPFLAGS
	MOV	AL,"-"
	CALL	CHOUT
	CALL	INBUF
	CALL	SCANB
	XOR	BX,BX
	MOV	DX,[FSAVE]
GETFLG:
	MOV	SI,DI
	LODSW
	CMP	AL,13
	JZ	SAVCHG
	CMP	AH,13
	JZ	FLGERR
	MOV	DI,FLAGTAB
	MOV	CX,32
	PUSH	CS
	POP	ES
	REPNE
	SCASW
	JNZ	FLGERR
	MOV	CH,CL
	AND	CL,0FH
	MOV	AX,1
	ROL	AX,CL
	TEST	AX,BX
	JNZ	REPFLG
	OR	BX,AX
	OR	DX,AX
	TEST	CH,16
	JNZ	NEXFLG
	XOR	DX,AX
NEXFLG:
	MOV	DI,SI
	PUSH	DS
	POP	ES
	CALL	SCANP
	JMP	GETFLG
DISPREGLINE:
	CS
	LODSW
	CALL	CHOUT
	MOV	AL,AH
	CALL	CHOUT
	MOV	AL,"="
	CALL	CHOUT
	MOV	DX,[BX]
	INC	BX
	INC	BX
	CALL	OUT16
	CALL	BLANK
	CALL	BLANK
	LOOP	DISPREGLINE
	RET
REPFLG:
	MOV	AX,4600H+"D"	;DF ERROR
FERR:
	CALL	SAVCHG
ERR:
	CALL	CHOUT
	MOV	AL,AH
	CALL	CHOUT
	MOV	SI,ERRMES
	JMP	PRINT
SAVCHG:
	MOV	[FSAVE],DX
	RET
FLGERR:
	MOV	AX,4600H+"B"	;BF ERROR
	JMP	FERR
DISPFLAGS:
	MOV	SI,FLAGTAB
	MOV	CX,16
	MOV	DX,[FSAVE]
DFLAGS:
	CS
	LODSW
	SHL	DX,1
	JC	FLAGSET
	CS
	MOV	AX,[SI+30]
FLAGSET:
	OR	AX,AX
	JZ	NEXTFLG
	CALL	CHOUT
	MOV	AL,AH
	CALL	CHOUT
	CALL	BLANK
NEXTFLG:
	LOOP	DFLAGS
	RET

;Trace 1 instruction or the number of instruction specified
;by the parameter using 8086 trace mode. Registers are all
;set according to values in save area

TRACE:
	CALL	SCANP
	CALL	HEXIN
	MOV	DX,1
	JC	STOCNT
	MOV	CX,4
	CALL	GETHEX
STOCNT:
	MOV	[TCOUNT],DX
	CALL	GETEOL
STEP:
	MOV	WORD [BRKCNT],0
	OR	BYTE [FSAVE+1],1
EXIT:
	MOV	WORD [12],BREAKFIX
	MOV	[14],CS
	MOV	WORD [4],REENTER
	MOV	[6],CS
	CLI
	MOV	WORD [64H],REENTER
	MOV	[66H],CS
	MOV	SP,STACK
	POP	AX
	POP	BX
	POP	CX
	POP	DX
	POP	BP
	POP	BP
	POP	SI
	POP	DI
	POP	ES
	POP	ES
	POP	SS
	MOV	SP,[SPSAVE]
	PUSH	WORD [FSAVE]
	PUSH	WORD [CSSAVE]
	PUSH	WORD [IPSAVE]
	MOV	DS,[DSSAVE]
	IRET
STEP1:	JMP	STEP

;Re-entry point from breakpoint. Need to decrement instruction
;pointer so it points to location where breakpoint actually
;occured.

BREAKFIX:
	XCHG	SP,BP
	DEC	WORD [BP]
	XCHG	SP,BP

;Re-entry point from trace mode or interrupt during
;execution. All registers are saved so they can be
;displayed or modified.

REENTER:
	CS
	MOV	[SPSAVE+SEGDIF],SP
	CS
	MOV	[SSSAVE+SEGDIF],SS
	XOR	SP,SP
	MOV	SS,SP
	MOV	SP,RSTACK
	PUSH	ES
	PUSH	DS
	PUSH	DI
	PUSH	SI
	PUSH	BP
	DEC	SP
	DEC	SP
	PUSH	DX
	PUSH	CX
	PUSH	BX
	PUSH	AX
	PUSH	SS
	POP	DS
	MOV	SP,[SPSAVE]
	MOV	SS,[SSSAVE]
	POP	WORD [IPSAVE]
	POP	WORD [CSSAVE]
	POP	AX
	AND	AH,0FEH
	MOV	[FSAVE],AX
	MOV	[SPSAVE],SP
	PUSH	DS
	POP	ES
	PUSH	DS
	POP	SS
	MOV	SP,STACK
	MOV	WORD [64H],CHINT
	MOV	AL,20H
	OUT	BASE+2,AL
	STI
	CLD
	CALL	CRLF
	CALL	DISPREG
	DEC	WORD [TCOUNT]
	JNZ	STEP1
ENDGO:
	MOV	SI,BPTAB
	MOV	CX,[BRKCNT]
	JCXZ	COMJMP
CLEARBP:
	MOV	DX,[SI+BPLEN]
	LODSW
	PUSH	AX
	CALL	GETSEG
	MOV	ES,AX
	MOV	DI,DX
	POP	AX
	STOSB
	LOOP	CLEARBP
COMJMP:	JMP	COMMAND

;Input from the specified port and display result

INPUT:
	MOV	CX,4		;Port may have 4 digits
	CALL	GETHEX		;Get port number in DX
	IN	AL,DX		;Variable port input
	CALL	HEX		;And display
	JMP	CRLF

;Output a value to specified port.

OUTPUT:
	MOV	CX,4		;Port may have 4 digits
	CALL	GETHEX		;Get port number
	PUSH	DX		;Save while we get data
	MOV	CX,2		;Byte output only
	CALL	GETHEX		;Get data to output
	XCHG	AX,DX		;Output data in AL
	POP	DX		;Port in DX
	OUT	DX,AL		;Variable port output
	RET

;Jump to program, setting up registers according to the
;save area. Up to 10 breakpoint addresses may be specified.

GO:
	MOV	BX,LINEBUF
	XOR	SI,SI
GO1:
	CALL	SCANP
	JZ	EXEC
	MOV	CX,5
	CALL	GETHEX
	MOV	[BX],DX
	MOV	[BX-BPLEN+1],AH
	INC	BX
	INC	BX
	INC	SI
	CMP	SI,BPMAX+1
	JNZ	GO1
	MOV	AX,5000H+"B"	;BP ERROR
	JMP	ERR
EXEC:
	MOV	[BRKCNT],SI
	CALL	GETEOL
	MOV	CX,SI
	JCXZ	NOBP
	MOV	SI,BPTAB
SETBP:
	MOV	DX,[SI+BPLEN]
	LODSW
	CALL	GETSEG
	MOV	DS,AX
	MOV	DI,DX
	MOV	AL,[DI]
	MOV	BYTE [DI],0CCH
	PUSH	ES
	POP	DS
	MOV	[SI-2],AL
	LOOP	SETBP
NOBP:
	MOV	WORD [TCOUNT],1
	JMP	EXIT

;Console input interrupt handler. Used to interrupt commands
;or programs under execution (if they have interrupts
;enabled). Control-S causes a loop which waits for any other
;character to be typed. Control-C causes abort to command
;mode. All other characters are ignored.

CHINT:
	PUSH	AX		;Don't destroy accumulator
;Output End-of-Interrupt commands to slave 8259A. This
;wouldn't be necessary if Automatic End of Interrupt mode
;worked like it was supposed to!
	MOV	AL,20H
	OUT	BASE+2,AL
	IN	AL,DATA		;Get interrupting character
	AND	AL,7FH		;ASCII has only 7 bits
	CMP	AL,"S"-"@"	;Check for Control-S
	JNZ	NOSTOP
	CALL	CHIN		;Wait for continue character
NOSTOP:
	CMP	AL,"C"-"@"	;Check for Control-C
	JZ	BREAK
;Just ignore interrupt - restore AX and return
	POP	AX
	IRET
BREAK:
	CALL	CRLF
	JMP	COMMAND
REGTAB:
	DB	"AXBXCXDXSPBPSIDIDSESSSCSIPPC"
REGDIF:	EQU	AXSAVE-REGTAB

;Flags are ordered to correspond with the bits of the flag
;register, most significant bit first, zero if bit is not
;a flag. First 16 entries are for bit set, second 16 for
;bit reset.

FLAGTAB:
	DW	0
	DW	0
	DW	0
	DW	0
	DB	"OV"
	DB	"DN"
	DB	"EI"
	DW	0
	DB	"NG"
	DB	"ZR"
	DW	0
	DB	"AC"
	DW	0
	DB	"PE"
	DW	0
	DB	"CY"
	DW	0
	DW	0
	DW	0
	DW	0
	DB	"NV"
	DB	"UP"
	DB	"DI"
	DW	0
	DB	"PL"
	DB	"NZ"
	DW	0
	DB	"NA"
	DW	0
	DB	"PO"
	DW	0
	DB	"NC"

;Initialization table. First byte of each entry is no.
;of bytes to output to the corresponding port. That
;many initialization bytes follow.

INITTABLE:
;Port BASE+0 - Master 8259A. Intialization Command Word (ICW)
;One sets level-triggered mode, multiple 8259As, require
;ICW4.
	DB	1
	DB	19H
;Port BASE+1 - Master 8259A. ICW2 sets vector base to 10H
;ICW3 sets a slave on interrupt input 1; ICW4 sets buffered
;mode, as a master, with Automatic End of Interrupt, 8086
;vector; Operation Command Word (OCW) One sets interrupt
;mask to enable line 1 (slave 8259A) only.
	DB	4
	DB	10H,2,0FH,0FDH
;Port BASE+2 - Slave 8259A. ICW1 sets level-triggered mode,
;multiple 8259As, require ICW4.
	DB	1
	DB	19H
;Port BASE+3 - Slave 8259A. ICW2 sets vector base to 18H
;ICW3 sets slave address as 1; ICW4 sets buffered mode,
;as slave, with Automatic End of Interrupt (which doesn't
;work in slaves), 8086 vector; OCW1 sets interrupt mask
;to enable line 1 (serial receive) only.
	DB	4
	DB	18H,1,0BH,0FDH
;Port Base+4 - 9513 Data. 9513 has previously been set
;up for Counter 5 mode register with auto increment. Thus
;mode is set to 0B63H, which is no gating, count source is
;F1 (4 MHz), reload from load or hold, count down repetitively
;in binary, with output toggle. Load register is set to
;0007H, and Hold register is set to 0006H. Thus we
;alternately divide by 7 and 6, which is divided by 2 by
;the output toggle, thus providing a square wave of
;4 MHz/13 = 307.7 kHz, which divided by 16 in the 8251A
;provides 19,230 baud (0.16% high).
	DB	6
	DB	63H,0BH,7,0,6,0
;Port BASE+5 - 9513 Control. Load and arm counter 5,
;enabling baud rate generation. Then select counter
;5 mode register, in case baud rate wasn't right.
	DB	2
	DB	70H,5
;Port BASE+6 - 8251A Data. No initialization to this port.
	DB	0
;Port BASE+7 - 8251A Control. Since it is not possible to
;know whether the 8251A next expects a Mode Instruction or
;a Command Instruction, a dummy byte is sent which could
;safely be interpreted as either but guarantees it is now
;expecting a Command. The command sent is Internal Reset
;which causes it to start expecting a mode. The mode sent
;is for 2 stop bits, no parity, 8 data bits, 16X clock.
;This is followed by the command to error reset, enable
;transmitter and receiver, set RTS and DTR to +12V.
	DB	4
	DB	0B7H,77H,0CEH,37H
HEADER:	DB	13,10,10,"SCP 8086 Monitor 1.5",13,10+80H
SYNERR:	DB	'^'
ERRMES:	DB	" Error",13,10+80H
BACMES:	DB	8,32,8+80H

;Disk boot. Select one of the following routines by
;setting the equates at the start of this program.

BOOT:
	PUSH	DI
;
;************************************************
;
; Boot for SCP, Cromemco 4FDC, or 16FDC disk controller with either
; large or small disks. Loads track 0, sector 1 into LOAD.
;
	%if	SCP+CROMEMCO4FDC+CROMEMCO16FDC

	%if	SCP
DISK:	EQU	0E0H
	%endif

	%if	CROMEMCO4FDC+CROMEMCO16FDC
DISK:	EQU	30H
	MOV	AL,0FFH		; Select side 0.
	OUT	4,AL
	%endif

	%if	SCP+CROMEMCO16FDC
	IN	AL,BASE+15		; Get sense switch data.
	MOV	CL,3		; Shift bit 1 over to bit 4 so it
	ROL	AL,CL		;  can be used for large/small bit.
	AND	AL,10H		; Keep only the large/small bit.
	%endif

	%if	CROMEMCO16FDC
	OR	AL,21H		; Add the rest of the drive-select bits.
	%endif

	%if	SCP+CROMEMCO16FDC
	MOV	BH,AL		; Put drive select byte in BH.
	%endif

	%if	CROMEMCO4FDC
	MOV	BH,21H		; Drive-select byte.
	%endif

	%if	CROMEMCO16FDC
	MOV	AL,30H		; Turn on disk motors and
	OUT	DISK+4,AL	;  wait one second.
	MOV	CX,43716
MOTORDELAY:
	AAM			; 83 clocks.
	AAM			; 83 clocks.
	LOOP	MOTORDELAY	; 17 clocks.
	%endif

RETRY:
	MOV	AL,0D0H		; Force-interrupt command.
	OUT	DISK,AL
	MOV	CX,5
DELAY:
	AAM			; Give force-interrupt time.
	LOOP	DELAY

	%if	SCP
	XOR	BH,08H		; If SCP, flip density bit.
	%endif

	%if	CROMEMCO16FDC
	XOR	BH,40H		; If 16FDC, flip density bit.
	%endif

	%if	CROMEMCO4FDC
	XOR	BH,10H		; If 4FDC, flip disk size bit.
	%endif

	MOV	AL,BH

	%if	SCP
	OR	AL,80H		; Turn on RESTORE for PerSci's.
	%endif

	OUT	DISK+4,AL
	MOV	DI,LOAD
	MOV	AL,0FH		; Restore command.
	OUT	DISK,AL
HOME:
	IN	AL,DISK+4		; Wait for INTRQ.
	ROR	AL,1
	JNC	HOME

	%if	SCP
	MOV	AL,BH		; Turn RESTORE off.
	OUT	DISK+4,AL
	%endif

	IN	AL,DISK		; Read status.
	AND	AL,98H
	JNZ	RETRY		; Retry if bad.
	MOV	AL,1		; Ask for sector 1.
	OUT	DISK+2,AL

	%if	CROMEMCO4FDC+CROMEMCO16FDC
	MOV	AL,BH
	OR	AL,80H		; Turn on auto-wait.
	OUT	DISK+4,AL
	%endif

	MOV	DX,DISK+3	; Disk controller data port.
	MOV	AL,8CH		; Read command.
	OUT	DISK,AL
	JMP	SHORT READ
READLOOP:
	STOSB			; Put data in memory.
READ:

	%if	SCP
	IN	AL,DISK+5		; Wait for DQR or INTRQ.
	%endif

	%if	CROMEMCO4FDC+CROMEMCO16FDC
	IN	AL,DISK+4
	%endif

	ROR	AL,1		; Check for INTRQ.
	IN	AL,DX		; Read data from disk controller chip.
	JNC	READLOOP	; Jump if not.
	IN	AL,DISK		; Get status.
	AND	AL,9CH
	JNZ	RETRY		; Jump if error.
	%endif
;
;***************************************************
;
; Boot for North Star disk, single density.
; Loads track 0, sector 0 into address LOAD
;
	%if	NORTHSTARSD
;
; Disk command equates
;
SEL:	EQU	1
STP1:	EQU	9
STP2:	EQU	8
NOP:	EQU	10H
SEC:	EQU	14H
STPOUT:	EQU	1CH
RD:	EQU	40H
BST:	EQU	20H

	PUSH	DS
	MOV	AX,0FEB8H
	MOV	DS,AX
	MOV	AL,[SEL]
	MOV	CX,20
MOTOR:
	CALL	SECTOR
	LOOP	MOTOR
CHKTRK:
	TEST	BYTE [STPOUT],1
	JNZ	ONTRACK
	MOV	AL,[STP1]
	AAM
	MOV	AL,[STP2]
	CALL	SECTOR
	CALL	SECTOR
	JMP	CHKTRK
SECTOR:
	MOV	AL,[SEC]	; Reset sector flag.
SECLP:
	TEST	BYTE [NOP],80H	; Wait for sector flag.
	JZ	SECLP
	RET
ONTRACK:
	MOV	DI,LOAD
	MOV	CX,280
	MOV	BX,RD+NOP
GETSEC:
	CALL	SECTOR
	TEST	BYTE [BST+NOP],0FH	; Test for sector zero.
	JNZ	GETSEC
GETSYNC:
	TEST	BYTE [NOP],4
	LOOPZ	GETSYNC
	JZ	ONTRACK
	MOV	CX,100H
	XOR	DL,DL
	AAD
READ:
	MOV	AL,[BX]
	STOSB			;Uses ES
	XOR	DL,AL
	ROL	DL
	AAD
	LOOP	READ
	MOV	AL,[BX]
	CMP	AL,DL
	JNZ	ONTRACK
	POP	DS
	%endif
;
; ********************************************************************
;
; Boot for Tarbell disk controllers. Load track 0, sector 1 into LOAD.
;
	%if	TARBELLSD+TARBELLDD
DISK:	EQU	78H

	%if	TARBELLDD
	SUB	AH,AH		; Initial drive-select byte = 0.
	%endif

	JMP	RETRY
DCOM:
	OUT	DISK,AL
	MOV	AL,50
HOLD:
	DEC	AL
	JNZ	HOLD
	RET

RETRY:
	MOV	AL,0D0H
	CALL	DCOM
READY:
	IN	AL,DISK
	ROR	AL
	JC	READY

	%if	TARBELLDD
	XOR	AH,08H		; Try other density.
	MOV	AL,AH
	OUT	DISK+4,AL
	%endif

	MOV	DI,LOAD
	MOV	AL,0EH		; Home command @ 10ms/track
	CALL	DCOM
	IN	AL,DISK+4
	IN	AL,DISK
	AND	AL,98H
	JNZ	RETRY
	MOV	AL,1
	OUT	DISK+2,AL
	MOV	DX,DISK+3	; Disk controller data port.
	MOV	AL,8CH
	CALL	DCOM
	JMPS	READ
READLOOP:
	STOSB			; Put in memory.
READ:
	IN	AL,DISK+4		; Wait for DRQ or INTRQ.
	ROL	AL		; Check for INTRQ.
	IN	AL,DX		; Read data from disk controller chip.
	JC	READLOOP	; Jump if not.
	IN	AL,DISK		; Read status.
	AND	AL,9CH
	JNZ	RETRY
	%endif

;***************************************************

	%if	OTHER

;User may insert customized disk boot here. All
;registers are available, stack pointer is valid
;and interrupts are enabled. Stack should be at
;same level on fall-through to code below. Last
;address available is 07DF hex.

	ORG	7E0H	;Simulate boot of maximum length

	%endif

;***************************************************

;Successful read
	MOV	WORD [CSSAVE],0
	MOV	WORD [IPSAVE],LOAD
	POP	DI
	JMP	GO
