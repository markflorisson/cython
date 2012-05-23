#
### Code Generators
#

class CodeGen(object):
    """
    Generate code for a specialization of a node. Set as the _codegen
    attribute of Node.
    """

    def __init__(self, node, specialization_kwargs):
        self.node = node
        self.specialization_kwargs = specialization_kwargs

    def generate_code(self, code, context):
        "Generate code for this node and the subexpressions"
        for subexpr in self.node.subexprs:
            subexpr.generate_code(code, context)
        self.generate_evaluation_code(code, context)


    def generate_disposal_code(self, code, context):
        "Generate disposal code for this node and the subexpressions"
        for subexpr in self.node.subexprs:
            subexpr.generate_disposal_code(code, context)
        self.generate_cleanup_code(code, context)

    def generate_evaluation_code(self, code, context):
        "Generate code for this node only. Override in subclasses."


    def generate_cleanup_code(self, code, context):
        "Generate some cleanup code. Override in subclasses."

    def result(self):
        """
        Return an expression which may be evaluated without sideeffects.

        E.g. for C/C++, this means a simple C expression, such as a variable
        reference, a constant, a struct attribute reference, etc.
        """

    def begin_loop(self, code, context, loop_level, index):
        """
        Marks the beginning of a nditerate loop for all subexpressions.
        Override in subclasses, but call this via super() to visit subexprs
        """
        for subexpr in self.node.subexprs:
            subexpr.begin_loop(context, loop_level, index)

    def end_loop(self, code, context, loop_level, index):
        """
        Marks the end of a nditerate loop for all subexpressions.
        Override in subclasses, but call this via super() to visit subexprs
        """
        for subexpr in self.node.subexprs:
            subexpr.end_loop(context, loop_level, index)

class IndicesCollectingCodeGen(CodeGen):

    def __init__(self, node):
        super(IndicesCollectingCodeGen, self).__init__(node)
        self.indices = []

    def begin_loop(self, code, context, loop_level, index):
        super(IndicesCollectingCodeGen, self).begin_loop(context, loop_level, index)
        self.indices.append(index)

class NDIteratorCodeGen(CodeGen):
    def generate_evaluation_code(self, code, context):
        ops = self.node.array_operands
        # the 'key' argument to max is new in 2.5
        max_ndim = max(op.type.ndim for op in ops)

        self.begin_loops(code, context, max_ndim)

    def begin_loops(self, code, context, max_ndim):
        error_handler = None
        if self.node.body.may_error():
            error_handler = context.error_handler(code)

        for loop_level in range(max_ndim):
            code.declaration_levels.append(code.insertion_point())
            code.loop_levels.append(code.insertion_point())

            index = self.put_loop(code, context, loop_level)
            self.node.body.begin_loop(code, context, loop_level, index)

        self.node.body.generate_code(code, context)

        if error_handler:
            error_handler.catch_here(code)
            error_handler.cascade(code)

        for i in range(max_ndim - 1, -1, -1):
            #code.cleanup_labels.append(Label('cleanup%s' % i))
            #code.cleanup_points.append(code.insertion_point())
            self.node.body.end_loop(code, context, loop_level, index)

        self.node.body.generate_disposal_code(code, context)

class StridedNDIteratorCodeGen(CodeGen):
    def put_loop(self, code, context, loop_level):
        i = code.loop_levels[-1].allocate_temp(c_py_ssize_t)
        extent = self.node.extent(loop_level)
        code.putln("for (%s = 0; %s < %s; %s++) {" % (i, i, extent, i))
        return i

class StridedElementalBinopCodeGen(IndicesCollectingCodeGen):
    def result(self):
        return "(%s %s %s)" % (self.lhs.result(), self.operator, self.rhs.result())

class CastNodeCodeGen(CodeGen):
    def result(self):
        arg = self.node.operands[0]
        return "((%s) %s)" % (self.node.type.cast(), arg.result())

class DereferenceCodeGen(CodeGen):
    def result(self):
        arg = self.node.operands[0]
        return "(*%s)" % arg.result()

class ArrayOperandWrapperCodeGen(IndicesCollectingCodeGen):

    def generate_evaluation_code(self, code, context):
        ndim = len(self.node.type.axes)
        assert len(self.indices) >= ndim
        indices = self.indices[len(self.indices) - ndim:]

        def mul(lhs, rhs, type=c_py_ssize_t):
            return Binop(self.node.pos, type, lhs, rhs, '*')

        def mul(lhs, rhs, type=c_char_t.pointer()):
            return Binop(self.node.pos, type, lhs, rhs, '+')

        pointer_node = self.node.element_pointer()
        bufp = CastNode(self.node.pos, c_char_t, [self.node.element_pointer()])
        for i, index in enumerate(indices):
            bufp = add(bufp, mul(index, self.node.stride(i)))

        bufp = CastNode(bufp.pos, self.node.type.pointer(), [bufp])
        bufp = DereferenceNode.from_node(bufp)
        bufp = bufp.specialize(context, **self.specialization_kwargs)
        bufp.generate_evaluation_code(code, context)
        self.bufp = bufp

    def result(self):
        return self.bufp.result()