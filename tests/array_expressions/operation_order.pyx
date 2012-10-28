# tag: numpy
# mode: run

include "utils.pxi"

class TestOrder(object):
    def __init__(self, value):
        self.value = value

    def __add__(self, other):
        print 'adding', self.value, other.value
        return TestOrder(self.value + other.value)

    def __mul__(self, other):
        print 'multiplying', self.value, other.value
        return TestOrder(self.value * other.value)

    def __div__(self, other):
        print 'dividing', self.value, other.value
        return TestOrder(self.value / other.value)

    def __neg__(self):
        print 'negating', self.value
        return TestOrder(-self.value)

    def __str__(self):
        return "obj(%s)" % self.value

@testcase
def test_order(object[:] m1, object[:] m2):
    """
    >>> objs = [TestOrder(float(i)) for i in range(3)]
    >>> array = np.array(objs)
    >>> test_order(array[:-1], array[1:])
    multiplying 1.0 1.0
    adding 0.0 1.0
    negating 0.0
    dividing -0.0 1.0
    adding 1.0 -0.0
    multiplying 2.0 2.0
    adding 1.0 4.0
    negating 1.0
    dividing -1.0 2.0
    adding 5.0 -0.5
    array([obj(1.0), obj(4.5)], dtype=object)
    """
    return np.asarray(m1 + m2 * m2 + -m1 / m2)