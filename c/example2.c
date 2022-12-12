//This example follows on from example1.c
#include <stdio.h>
#include <stdlib.h>

void func(int **b) {
   *b = (int*)malloc(sizeof(int));
   **b = 400;

   printf("%d\n", **b); //What will print here
}

int main() {
   int **a = (int**)malloc(sizeof(int*));
   func(a);
   printf("%d\n", **a); //Why does this work?
}