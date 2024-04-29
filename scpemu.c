// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * A minimal emulator of a SCP 8086 board, just enough to get serial I/O
 * working with the SCP 8086 Monitor ROMs.
 *
 * Copyright (C) 2024 Lubomir Rintel <lkundrak@v3.sk>
 */

#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#include <x86emu.h>

x86emu_t *emu;

static struct termios *orig_tio = NULL;
static x86emu_memio_handler_t orig_memio = NULL;
static int term = 0;

static int uart_ch = '\0';
static void
tryrx (void)
{
	if (uart_ch == '\0') {
		uart_ch = getc (stdin);
		if (uart_ch == EOF) {
			if (errno != EAGAIN) {
				perror ("getchar");
				x86emu_stop (emu);
			}
			uart_ch = '\0';
		} else if (uart_ch == '\n') {
			uart_ch = '\r';
		}
	}
}

static unsigned
memio_handler (x86emu_t *emu, u32 addr, u32 *val, unsigned type)
{
	if (term)
		x86emu_stop (emu);

	switch (type) {
	case X86EMU_MEMIO_8 | X86EMU_MEMIO_I:
	case X86EMU_MEMIO_16 | X86EMU_MEMIO_I:
		*val = 0xff;
		switch (addr) {
		case 0x00f6:
			tryrx ();
			*val = uart_ch;
			uart_ch = '\0';
			x86emu_log (emu, "0x%04x ->0x%04x 8251A #1 Data\n", addr, *val);
			return 0;
		case 0x00f7:
			tryrx ();
			*val = 0x01; /* transmitter ready */
			if (uart_ch != '\0')
				*val |= 0x02; /* data available */
			x86emu_log (emu, "0x%04x ->0x%04x 8251A #1 Control\n", addr, *val);
			return 0;

		case 0x0ff:
			/*
			 * 000xxxxx ignored
			 * xxx00xxx baud=9600
			 * xxx01xxx baud=19.2K
			 * xxx11xxx baud=300
			 * xxxxx0xx floppy boot
			 * xxxxx1xx hard boot
			 * xxxxxx1x large
			 * xxxxxx0x small
			 * xxxxxxx1 autoboot
			 * xxxxxxx0 noautoboot
			*/
			*val = 0x1e;
			x86emu_log (emu, "0x%04x -> 0x%04x Sense switch port\n", addr, *val);
			return 0;

		case 0x00e0:
		case 0x00e4:
		case 0x00e3:
		case 0x00e5:
		default:
			*val = 0xff;
			fprintf (stderr, "Unhandled read from port 0x%04x -> 0x%04x\n", addr, *val);
			x86emu_stop (emu); break;
			return 0;

		}
		break;

	case X86EMU_MEMIO_8 | X86EMU_MEMIO_O:
	case X86EMU_MEMIO_16 | X86EMU_MEMIO_O:
		switch (addr) {
		case 0x00f0:
			x86emu_log (emu, "0x%04x <- 0x%04x Master 8259A\n", addr, *val);
			return 0;
		case 0x00f1:
			x86emu_log (emu, "0x%04x <- 0x%04x Master 8259A\n", addr, *val);
			return 0;
		case 0x00f2:
			x86emu_log (emu, "0x%04x <- 0x%04x Slave 8259A\n", addr, *val);
			return 0;
		case 0x00f3:
			x86emu_log (emu, "0x%04x <- 0x%04x Slave 8259A\n", addr, *val);
			return 0;
		case 0x00f4:
			x86emu_log (emu, "0x%04x <- 0x%04x 9513 Data\n", addr, *val);
			return 0;
		case 0x00f5:
			x86emu_log (emu, "0x%04x <- 0x%04x 9513 Control\n", addr, *val);
			return 0;
		case 0x00f6:
			x86emu_log (emu, "0x%04x <- 0x%04x 8251A #1 Data\n", addr, *val);
			if (*val == 0x8a)
				printf ("\n");
			else
				printf ("%c", *val);
			fflush (stdout);
			return 0;
		case 0x00f7:
			x86emu_log (emu, "0x%04x <- 0x%04x 8251A #1 Control\n", addr, *val);
			return 0;
		case 0x00f9:
			x86emu_log (emu, "0x%04x <- 0x%04x 8251A #2 Control\n", addr, *val);
			return 0;
		case 0x00fa:
			x86emu_log (emu, "0x%04x <- 0x%04x Baud rate 1\n", addr, *val);
			return 0;
		case 0x00fb:
			x86emu_log (emu, "0x%04x <- 0x%04x Baud rate 2\n", addr, *val);
			return 0;

		case 0x0054:
		case 0x0055:
		case 0x00e0:
		case 0x00e4:
		case 0x00e2:
		default:
			fprintf (stderr, "Unhandled write to port 0x%04x <- 0x%04x\n", addr, *val);
			x86emu_stop (emu);
		}
		break;
	}

	/* Proceed, but wrap around the address. */
	return orig_memio (emu, addr & 0xfffff, val, type);
}

static void
cleanup (void)
{
	if (orig_tio) {
		if (tcsetattr (STDIN_FILENO, TCSANOW, orig_tio) == -1)
			perror ("cleanup: tcsetattr");
		orig_tio = NULL;
	}

	if (emu) {
		x86emu_dump (emu, X86EMU_DUMP_DEFAULT | X86EMU_DUMP_ACC_MEM);
		x86emu_clear_log (emu, 1);
		x86emu_done (emu);
		emu = NULL;
	}
}

static void
sigint2 (int signum)
{
	cleanup ();
	signal (SIGINT, SIG_DFL);
}

static void
sigint1 (int signum)
{
	term = 1;
	signal (SIGINT, sigint2);
}

static void
sighup2 (int signum)
{
	cleanup ();
	signal (SIGHUP, SIG_DFL);
}

static void
sighup1 (int signum)
{
	term = 1;
	signal (SIGHUP, sighup2);
}

static void
flush_log (x86emu_t *emu, char *buf, unsigned size)
{
	if (!buf || !size) return;

	fwrite (buf, size, 1, stderr);
	fflush (stderr);
}

int
main (int argc, char *argv[])
{
	struct termios tio, tio_raw;
	struct stat statbuf;
	unsigned addr;
	unsigned flags;
	unsigned ret;
	int f;
	int debug = 0;
	char c;

	if (argc != 2) {
		fprintf (stderr, "Usage: %s <rom> [<floppy>]\n", argv[0]);
		return 1;
	}

	emu = x86emu_new (X86EMU_PERM_R | X86EMU_PERM_W | X86EMU_PERM_X, 0);
	x86emu_set_seg_register (emu, emu->x86.R_CS_SEL, 0xf000);
	emu->x86.R_IP = 0xfff0;

	f = open (argv[1], O_RDONLY);
	if (f == -1) {
		perror (argv[1]);
		return 1;
	}
	if (fstat (f, &statbuf) == -1) {
		perror (argv[1]);
		return 1;
	}

	if (statbuf.st_size != 0x1000 && statbuf.st_size != 0x800) {
		fprintf (stderr, "Wrong ROM size: %ld\n", statbuf.st_size);
		return 1;
	}

	for (addr = 0x100000 - statbuf.st_size; addr < 0x100000; addr++) {
		switch (read (f, &c, 1)) {
		case 0:
			break;
		case 1:
			x86emu_write_byte (emu, addr, c);
			continue;
		case -1:
		default:
			perror (argv[1]);
			return 1;
		}
		break;
	}
	close (f);

	orig_memio = x86emu_set_memio_handler (emu, memio_handler);

	emu->max_instr = 100;
	flags = X86EMU_RUN_NO_EXEC | X86EMU_RUN_NO_CODE | X86EMU_RUN_LOOP;

	if (getenv ("DEBUG"))
		debug = 1;

	if (debug) {
		x86emu_set_log (emu, 0x100000, flush_log);
		emu->log.trace = X86EMU_TRACE_DEFAULT;
	}

	if (tcgetattr (STDIN_FILENO, &tio) == -1) {
		perror ("tcgetattr");
		return 1;
	}
	orig_tio = &tio;

	tio_raw = tio;
	tio_raw.c_lflag &= ~ (ECHO | ECHONL | ICANON | IEXTEN);
	if (tcsetattr (STDIN_FILENO, TCSANOW, &tio_raw) == -1) {
		perror ("tcsetattr");
		return 1;
	}

	if (fcntl (STDIN_FILENO, F_SETFL, O_NONBLOCK) == -1) {
		perror ("F_SETFL");
		return 1;
	}

	signal (SIGINT, sigint1);
	signal (SIGHUP, sighup1);
	ret = x86emu_run (emu, flags);
	cleanup ();

	return !!ret;
}
