#include <stdio.h>
#include <stdlib.h>

void func(int* b) {
   b = (int*)malloc(sizeof(int)); //What is malloc? Why can't I use new? What's the difference
   *b = 400;
   printf("%d\n", *b); //What will print here
}

int main() {
  int* a = 0;
  func(a);
  printf("%d\n", *a); //Error - but why? Also, is there a memory leak?
}