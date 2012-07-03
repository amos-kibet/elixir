import Elixir.Builtin, except: [to_binary: 1]

defmodule Macro do
  @moduledoc """
  This module provides conveniences for working with macros.
  """

  @doc """
  Recursively escapes the given value so it can be inserted
  into a syntax tree. Structures that are valid syntax nodes
  (like atoms, integers, binaries) are represented by themselves.

  ## Examples

      Macro.escape(:foo)
      #=> :foo

      Macro.escape({ :a, :b, :c })
      #=> { :{}, 0, [:a, :b, :c] }
  """
  def escape({ left, right }) do
    { escape(left), escape(right) }
  end

  def escape(tuple) when is_tuple(tuple) do
    { :{}, 0, escape(tuple_to_list(tuple)) }
  end

  def escape(list) when is_list(list) do
    lc item inlist list, do: escape(item)
  end

  def escape(other), do: other

  @doc """
  Converts the given expression to a binary.

  ## Examples

      Macro.to_binary(quote do: foo.bar(1, 2, 3))
      #=> "foo.bar(1, 2, 3)"

  """

  def to_binary(tree)

  # Variables
  def to_binary({ var, _, atom }) when is_atom(atom) do
    atom_to_binary(var, :utf8)
  end

  # Aliases
  def to_binary({ :__aliases__, _, refs }) do
    Enum.map_join(refs, ".", call_to_binary(&1))
  end

  # Blocks
  def to_binary({ :__block__, _, exprs }) do
    joined = Enum.map_join(exprs, "\n", to_binary(&1))
    spaced = bc <<x>> inbits joined do
      << case x == ?\n do
        true  -> "\n  "
        false -> <<x>>
      end | :binary >>
    end
    "(\n  " <> spaced <> "\n)"
  end

  # Bits containers
  def to_binary({ :<<>>, _, args }) do
    "<<" <> Enum.map_join(args, ", ", to_binary(&1)) <> ">>"
  end

  # Tuple containers
  def to_binary({ :{}, _, args }) do
    "{" <> Enum.map_join(args, ", ", to_binary(&1)) <> "}"
  end

  # List containers
  def to_binary({ :[], _, args }) do
    "[" <> Enum.map_join(args, ", ", to_binary(&1)) <> "]"
  end

  # All other calls
  def to_binary({ target, _, args }) when is_list(args) do
    args = Enum.map_join(args, ", ", to_binary(&1))
    call_to_binary(target) <> "(" <> args <> ")"
  end

  # Two-item tuples
  def to_binary({ left, right }) do
    to_binary({ :{}, 0, [left, right] })
  end

  # Lists
  def to_binary(list) when is_list(list) do
    to_binary({ :[], 0, list })
  end

  # All other structures
  def to_binary(other), do: Binary.Inspect.inspect(other)

  defp call_to_binary(atom) when is_atom(atom),  do: atom_to_binary(atom, :utf8)
  defp call_to_binary({ :., _, [arg] }),         do: call_to_binary(arg) <> "."
  defp call_to_binary({ :., _, [left, right] }), do: call_to_binary(left) <> "." <> call_to_binary(right)
  defp call_to_binary(other),                    do: to_binary(other)

  @doc """
  Receives an expression representation and expands it. The following
  contents are expanded:

  * Macros (local or remote);
  * Aliases are expanded (if possible) and return atoms;
  * All pseudo-variables (__FILE__, __MODULE__, etc);

  In case the expression cannot be expanded, it returns the expression itself.

  ## Examples

  In the example below, we have a macro that generates a module
  with a function named `name_length` that returns the length
  of the module name. The value of this function will be calculated
  at compilation time and not at runtime.

  Consider the implementation below:

      defmacro defmodule_with_length(name, do: block) do
        length = length(atom_to_list(name))

        quote do
          defmodule unquote(name) do
            def name_length, do: unquote(length)
            unquote(block)
          end
        end
      end

  When invoked like this:

      defmodule_with_length My.Module do
        def other_function, do: ...
      end

  The compilation will fail because `My.Module` when quoted
  is not an atom, but a syntax tree as follow:

      {:__aliases__, 0, [:My, :Module] }

  That said, we need to expand the aliases node above to an
  atom, so we can retrieve its length. Expanding the node is
  not straight-forward because we also need to expand the
  caller aliases. For example:

      alias MyHelpers, as: My

      defmodule_with_length My.Module do
        def other_function, do: ...
      end

  The final module name will be `MyHelpers.Module` and not
  `My.Module`. With `Macro.expand`, such aliases are taken
  into consideration. Local and remote macros are also
  expanded. We could rewrite our macro above to use this
  function as:

      defmacro defmodule_with_length(name, do: block) do
        expanded = Macro.expand(name, __CALLER__)
        length   = length(atom_to_list(expanded))

        quote do
          defmodule unquote(name) do
            def name_length, do: unquote(length)
            unquote(block)
          end
        end
      end

  """
  def expand(aliases, env)

  # The first case we handle is __aliases__. In case
  # aliases just contain one item, we are sure it is
  # an atom, so we just expand it based on the aliases
  # dict.
  def expand({ :__aliases__, _, [h] }, env) do
    expand_alias(h, env)
  end

  # In case aliases contains more than one item, we need
  # to loop them checking if they are all atoms or not.
  # Macros and pseudo-variables are then expanded.
  def expand({ :__aliases__, _, [h|t] }, env) do
    aliases = case is_atom(h) do
      true  -> [expand_alias(h, env)|t]
      false -> [h|t]
    end

    aliases = lc alias inlist aliases, do: expand(alias, env)
    :lists.all(is_atom(&1), aliases) && Erlang.elixir_aliases.concat(aliases)
  end

  # Expand Erlang.foo calls
  def expand({ { :., _, [{ :__aliases__, _, [:Erlang] }, atom] }, _, args }, _env) when
    is_atom(atom) and (is_atom(args) or args == []), do: atom

  # Expand pseudo-variables
  def expand({ :__MAIN__, _, atom }, _env)  when is_atom(atom), do: :__MAIN__
  def expand({ :__MODULE__, _, atom }, env) when is_atom(atom), do: env.module
  def expand({ :__FILE__, _, atom }, env)   when is_atom(atom), do: env.file
  def expand({ :__ENV__, _, atom }, env)    when is_atom(atom), do: env

  # Expand possible macro import invocation
  def expand({ atom, line, args } = original, env) when is_atom(atom) do
    args = case is_atom(args) do
      true  -> []
      false -> args
    end

    case not is_partial?(args) do
      false -> original
      true  ->
        expand = Erlang.elixir_dispatch.expand_import(line, { atom, length(args) }, args,
          env.module, env.function, env.requires, env.macros, env)
        case expand do
          { :ok, _, expanded } -> expanded
          { :error, _ }     -> original
        end
    end
  end

  # Expand possible macro require invocation
  def expand({ { :., _, [left, right] }, line, args } = original, env) when is_atom(right) do
    receiver = expand(left, env)

    case is_atom(receiver) and not is_partial?(args) do
      false -> original
      true  ->
        expand = Erlang.elixir_dispatch.expand_require(line, receiver, { right, length(args) },
          args, env.module, env.function, env.requires, env)
        case expand do
          { :ok, expanded } -> expanded
          { :error, _ }     -> original
        end
    end
  end

  # Anything else is just returned
  def expand(other, _env), do: other

  ## Helpers

  defp is_partial?(args) do
    :lists.any(match?({ :&, _, [_] }, &1), args)
  end

  defp expand_alias(h, env) do
    atom = list_to_atom('__MAIN__-' ++ atom_to_list(h))
    Erlang.elixir_aliases.lookup(atom, env.aliases)
  end
end