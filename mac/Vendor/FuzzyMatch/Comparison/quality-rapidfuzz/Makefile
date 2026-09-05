CXX = clang++

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    INCLUDE_FLAGS = -I$(shell brew --prefix)/include
else
    INCLUDE_FLAGS = -I/usr/include
endif

CXXFLAGS = -std=c++17 -O3 -march=native -flto -DNDEBUG $(INCLUDE_FLAGS)
TARGET = quality-rapidfuzz

$(TARGET): main.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: clean
