//Ahhhh sanity! This example follows from example 1 and example 2.
//Notice how much neater it is

#include <iostream>
using namespace std;

void func(int*& b) {
   b = new int;
   *b = 200;
}

int main() {
   int * a;
   func(a);

   cout << *a << endl; //Why does this work?
}