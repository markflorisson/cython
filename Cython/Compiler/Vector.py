import copy
import types

import CodeGen

def specialize_module(CodeGen):
    mod = types.ModuleType(__name__)
    vars(mod).update(__dict__, CodeGen=CodeGen)
    return mod

class Context(object):
    """
    A context that knows how to map ASTs back and forth, how to wrap nodes
    and types, and how to instantiate a code generator for specialization.

        astmap: dict mapping AST node classes to our AST node classes
        codewriter: object to write code to (see CodeWriter)
        codeformatter:

    The idea is that all one has to do to customize this AST is to override
    the methods of this class and return objects with a compatible interface.
    For instance, if one wants to override the code generator for a multiply
    operation, all one has to either

        1) map the multiply node of the external AST to a multiply node
           (possibly as subclass of Binop)
        2) override the get_codegen method of this class and return a custom
           code generator (possibly as subclass of CodeGen)

                class Context(Vector.Context):
                    def get_codegen(self, node):
                        if node.type.is_scalar:
                            return CustomScalarCodeGen(node)
                        return super(Context, self).get_codegen(node)
        3) call specialize_module() with a custom CodeGen module (possibly
           selectively overriding default implementations)

    An opaque_node is a node that is not from our AST, and a normal node
    is one that has a interface compatible with ours.
    """

    def __init__(self, astmap, codewriter=None, codeformatter=None):
        self.astmap = astmap
        self.codeformatter = codeformatter or CodeStringFormatter()
        self.codewriter = codewriter or CodeWriter(self)

    #
    ### AST node and type mapping
    #

    def wrap_node(self, opaque_node, type):
        return NodeWrapper(opague_node.pos, opague_node.type, opaque_node)

    def specialize(self, opaque_node):
        return copy.deepcopy(opaque_node)

    def map_node(self, opaque_node):
        node = self.wrap_node(opaque_node)

        for base_class in type(node).__mro__:
            if base_class in self.astmap:
                return self.astmap[base_class](node.pos, node.type)

        if node.type.is_constant:
            return self.constant_scalar(node)
        elif node.type.is_scalar:
            return self.scalar(node)
        else:
            return node

    def constant_scalar(self, node):
        return ConstantScalar.from_node(node)

    def scalar(self, node):
        return Scalar.from_node(node)

    #
    ### Code generation
    #

    def get_codegen(self, node):
        if node._codegen is None:
            raise ValueError("Node was not specialized: %s" % (node,))
        return node._codegen(node)

    def error_handler(self, code):
        code.error_handler = ErrorHandler(code.error_handler)
        return code.error_handler

class CodeFormatter(object):
    def format(self, value):
        return value

    def format_values(self, values):
        "format all code values from the code tree flattened in a list"
        return values

class CodeStringFormatter(CodeFormatter):
    def format_values(self, values):
        return "".join(self.format(value) for value in self.values)


class CodeWriter(object):
    """
    Write code as objects for later assembly.

        loop_levels:
            CodeWriter objects just before the start of each loop
        tiled_loop_levels:
            same as loop levels, but takes into account tiled loop patterns
        cleanup_levels:
            CodeWriter objects just after the end of each loop
        declaration_levels:
            same as loop_levels, but a valid insertion point for
            C89 declarations
    """

    error_handler = None

    def __init__(self, context, buffer=None):
        self.buffer = buffer or _CodeTree(formatter)
        self.context = context

        self.loop_levels = []
        self.tiled_loop_levels = []
        self.cleanup_levels = []
        self.cleanup_labels = []
        self.declaration_levels = []

    @classmethod
    def clone(cls, other, context, buffer):
        return cls(context, buffer)

    def insertion_point(self, condition=None):
        "Create a (conditional) insertion point."
        return self.clone(context, self.buffer.insertion_point(condition))

    def write(self, value):
        self.buffer.output.append(value)

    def put_label(self, label):
        "Insert a label in the code"
        self.write(label)

    def put_goto(self, label):
        "Jump to a label. Implement in subclasses"

class Condition(object):
    """
    This wraps a condition so that it can be shared by everyone and modified
    by whomever wants to.
    """
    def __init__(self, value):
        self.value = value

    def __nonzero__(self):
        return self.value

class CCodeWriter(CodeWriter):
    def put_label(self, label):
        self.putln('%s:' % self.mangle(label.name))

    def put_goto(self, label):
        self.putln("goto %s;" % self.mangle(label.name))

    def mangle(self, varname):
        return '__pyx_mangled_%s' % varname

class TempitaCodeWriter(CodeWriter):

    def putln(self, string, context_dict):
        from Cython.Compiler.Code import sub_tempita
        self.write(sub_tempita(string) + '\n')

class _CodeTree(object):
    """
    See Cython/StringIOTree
    """

    def __init__(self, output=None, condition=None):
        self.prepended_children = []
        self.output = output or []
        self.condition = None

    def _getvalue(self, result):
        for child in self.prepended_children:
            child._getvalue(result)

    def getvalue(self):
        result = []
        self._getvalue(result)
        return result

    def clone(self, output=None):
        return type(self)(output, self.condition)

    def commit(self):
        if self.output:
            self.prepended_children.append(self.clone(self.output))
            self.output = []

    def insertion_point(self, condition=None):
        self.commit()
        ip = self.clone()
        if condition is not None:
            ip.condition = condition
        self.prepended_children.append(ip)
        return ip

class Label(object):
    "A point that can be jumped to"

    def __init__(self, name):
        self.name = name

class ComparableObjectMixin(object):

    def __hash__(self):
        "Implement in subclasses"
        raise NotImplementedError

    def __eq__(self, other):
        "Implement in subclasses"
        return NotImplemented

class Node(ComparableObjectMixin):

    _codegen = None

    is_scalar = False
    is_constant = False
    is_assignment = False
    is_unop = False
    is_binop = False

    is_node_wrapper = False
    is_array_wrapper = False

    def __init__(self, pos, type, codegen=None):
        self.pos = pos
        self.type = type
        self._codegen = codegen

    @property
    def subexprs(self):
        """
        Return a list of subexpressions. Override in subclasses.
        """

    def specialize(self, context, **kwds):
        """
        Specialize this node and prepare it for code generation (set the
        _codegen attribute). Override in subclasses.
        """

    def may_error(self):
        """
        Return whether something may go wrong and we need to jump to an
        error handler.
        """
        return [True for subexpr in self.subexprs if subexpr.may_error()]

    def generate_code(self, code, context):
        context.get_codegen(self).generate_code(code, context)

    def generate_disposal_code(self, code, context):
        context.get_codegen(self).generate_disposal_code(code, context)

    def begin_loop(code, context, loop_level, index):
        context.get_codegen(self).begin_loop(context, loop_level, index)

    def end_loop(code, context, loop_level, index):
        context.get_codegen(self).end_loop(context, loop_level, index)

    @classmethod
    def from_node(cls, other_node, pos=None, type=None, codegen=None):
        return cls(pos or other_node.pos,
                   type or other_node.type,
                   codegen=codegen or other_node._codegen)

class NodeWrapper(Node):
    """
    Adapt an opaque node to provide a consistent interface.
    """

    is_node_wrapper = True

    def __init__(self, pos, type, opaque_node):
        super(NodeWrapper, self).__init__(pos, type)
        self.opaque_node = opaque_node

    def specialize(self, context, **kwds):
        return context.specialize(self.opaque_node)

    def __hash__(self):
        return hash(self.opaque_node)

    def __eq__(self, other):
        if getattr(other, 'is_node_wrapper ', False):
            return self.opaque_node == other.opaque_node

        return NotImplemented

    @property
    def subexprs(self):
        return []

class ArrayOperandWrapper(NodeWrapper):
    """
    An array operand to the expression. It evaluates the array operand to
    the nditerate inside the loop to return a pointer to the current element's
    position.
    """

    is_array_wrapper = True

    def extent(self, i):
        "return the extent in dimension i"

    def stride(self, i):
        "return the stride in dimension i"

#
### Type System
#

class Type(ComparableObjectMixin):

    is_array = False
    is_scalar = False
    is_constant = False
    is_py_ssize_t = False

    def pointer(self):
        return PointerType(self)

    def __eq__(self, other):
        "Override in subclasses where needed :)"
        return type(self) == type(other)

    def __hash__(self):
        return hash(type(self))

class ArrayType(Type):

    is_array = True

    def __init__(self, dtype, axes):
        self.dtype = dtype
        self.axes = tuple(axes)

    def is_cf_contig(self):
        assert self.is_array
        return self.type.is_cf_contig()

    def __eq__(self, other):
        return (other.is_array and self.dtype == other.dtype and
                self.axes == other.axes)

    def __hash__(self):
        return hash(self.axes) ^ hash(self.dtype)

class Py_ssize_t_Type(Type):
    is_py_ssize_t = True

class CharType(Type):
    is_char = True

class TypeWrapper(Type):
    def __init__(self, opaque_type):
        self.opaque_type = opaque_type

c_py_ssize_t = Py_ssize_t_Type()
c_char_t = CharType()

class Operation(Node):

    def __init__(self, pos, type, operands, codegen=None):
        super(Operation, self).__init__(pos, type, codegen)
        self.operands = operands

    @property
    def subexprs(self):
        return self.operands

    @classmethod
    def from_node(cls, other_node, pos=None, type=None, operands=None,
                  codegen=None, **kwargs):
        result = cls(pos or other_node.pos,
                     type or other_node.type,
                     operands or other_node.operands,
                     codegen=codegen or other_node._codegen)
        vars(result).update(kwargs)
        return result

class NDIterator(Operation):

    def __init__(self, pos, type, body, array_operands, vector_size=None):
        super(NDInterator, self).__init__(pos, type, body)
        self.body, = body
        self.array_operands = array_operands
        self.vector_size = None

    def specialize(self, context, **kwds):
        return self.from_node(self, body=self.body,
                              array_operands=self.array_operands,
                              vector_size=self.vector_size)

class Binop(Elemental):

    is_binop = True

    def __init__(self, pos, type, operands, operator, codegen):
        super(ElementalUnop, self).__init__(pos, type, operands, codegen)
        self.lhs, self.rhs = operands
        self.operator = operator

    def is_cf_contig(self):
        c1, f1 = self.op1.is_cf_contig()
        c2, f2 = self.op2.is_cf_contig()
        return c1 and c2, f1 and f2

    def __hash__(self):
        return hash(self.operator) ^ hash(self.lhs) ^ hash(self.rhs)

    def __eq__(self, other):
        return (other.is_elemental and other.is_binop and
                self.operator == other.operator and
                self.lhs == other.lhs and self.rhs == other.rhs)

class Unop(Elemental):

    is_unop = True

    def __init__(self, pos, type, operand, operator, codegen):
        super(ElementalUnop, self).__init__(pos, type, operand, codegen=codegen)
        self.operand, = operand
        self.operator = operator

    def __hash__(self):
        return hash(self.operator) ^ hash(self.operand)

    def __eq__(self, other):
        return (other.is_elemental and other.is_unop and
                self.operator == other.operator and
                self.operand == other.operand)

class CastNode(Operation):
    def specialize(self, context, **kwds):
        return type(self)(self.pos, self.type, self.operands,
                          codegen=CodeGen.CastNodeCodeGen(self, kwds))

class DereferenceNode(Operation):
    def specialize(self, context, **kwds):
        return type(self)(self.pos, self.type, self.operands,
                          codegen=CodeGen.DereferenceCodeGen(self, kwds))

    @classmethod
    def from_node(cls, other_node):
        assert other_node.type.is_pointer
        super(DereferenceNode, cls).from_node(other_node,
                                              type=other_node.type.base_type)

class Scalar(Operation):
    """

    """

    is_scalar = True

class Assignment(Operation):
    """

    """

    is_assignment = True

class ErrorHandler(object):

    def __init__(self, previous_handler):
        self.prev = previous_handler
        if self.prev:
            self.cnt = self.prev.cnt + 1
        else:
            self.cnt = 0
        self.label = Label('error%d' % self.cnt)

        self.condition = Condition(False)

    def setup_error(self, code, context):
        conditional_point = code.insertion_point(condition=self.condition)
        self.error = conditional_point.allocate_temp(c_int_type)
        conditional_point.putln("%s = 0;" % self.error)

    def goto_error(self, code, cascade=False):
        """
        Jump to the error label. If cascade, jump to any parent error label.
        """
        code.put_goto(self.label)
        if cascade and self.prev:
            self.condition.value = True

    def catch_here(self, code):
        code.put_label(self.label)
        conditional_point = code.insertion_point(condition=self.condition)
        conditional_point.putln("%s = 1;" % self.error)

    def cascade(self, code):
        """
        Cascade error propagation.
        """
        if self.prev:
            code.putln("if (%s) {" % self.error)
            self.prev.goto_error(code, cascade=True)
            code.putln("}")