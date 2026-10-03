#include <stdio.h>
#include <stdint.h>
#include <osmocom/core/bits.h>
#include <osmocom/coding/gsm0503_coding.h>
int main(int c, char **v){uint8_t l2[23];ubit_t b[2048]={0};for(int i=0;i<23;i++){unsigned x;sscanf(v[1+i],"%x",&x);l2[i]=x;}
if(gsm0503_xcch_encode(b,l2))return 1;for(int i=0;i<456;i++)putchar('0'+b[i]);putchar('\n');return 0;}
