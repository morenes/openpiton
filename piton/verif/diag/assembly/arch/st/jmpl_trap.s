// Modified by Princeton University on June 9th, 2015
/*
* ========== Copyright Header Begin ==========================================
* 
* OpenSPARC T1 Processor File: jmpl_trap.s
* Copyright (c) 2006 Sun Microsystems, Inc.  All Rights Reserved.
* DO NOT ALTER OR REMOVE COPYRIGHT NOTICES.
* 
* The above named program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License version 2 as published by the Free Software Foundation.
* 
* The above named program is distributed in the hope that it will be 
* useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
* 
* You should have received a copy of the GNU General Public
* License along with this work; if not, write to the Free Software
* Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA.
* 
* ========== Copyright Header End ============================================
*/
/***********************************************************************
 * Name:   
 * Date:   
 *
 *
 *  Description:
 *  	jmpl -> mem_addr_unaligned trap
 *
 **********************************************************************/
#define H_HT0_Illegal_instruction_0x10 my_illegal_instruction
#define H_T0_Privileged_opcode_0x11 my_privileged_opcode
#define H_HT0_Mem_Address_Not_Aligned_0x34 my_mem_addr

	
#include "boot.s"

.text
.global main  
	
main:
        mov %g0, %l0    ! counter
        mov %g0, %l1    ! counter2
        mov %g0, %l2    ! counter_mem

	setx checking, %l3, %g2
	inc %g2
	jmp %g2
	nop
	
checking:       
        cmp %l2, 1
        bne fail
        nop

pass:
	ta		T_GOOD_TRAP

fail:
	ta		T_BAD_TRAP



SECTION .USER_TRAP_FOR_HYP TEXT_VA=0x13002000
attr_text {
        Name = .USER_TRAP_FOR_HYP,
        hypervisor
        }

.global my_illegal_instruction
.global my_mem_addr
my_illegal_instruction:
        inc %l0
        done
        nop

my_mem_addr:	
        inc %l2
        done
        nop
	


SECTION .USER_TRAP_FOR_SUP TEXT_VA=0x3006000
attr_text {
        Name = .USER_TRAP_FOR_SUP,
        RA=0x3006000,
        PA=ra2pa(0x3006000,0),
        part_0_i_ctx_zero_ps0_tsb,
        TTE_G=0, TTE_Context=0, TTE_V=1, TTE_Size=0x0, TTE_NFO=0,
        TTE_IE=0, TTE_Soft2=0, TTE_Diag=0, TTE_Soft=0,
        TTE_L=0, TTE_CP=1, TTE_CV=0, TTE_E=0, TTE_P=1, TTE_W=0
        }

.global my_privileged_opcode
my_privileged_opcode:
        inc %l1
        done
        nop
