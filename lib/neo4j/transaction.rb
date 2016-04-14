
module Neo4j
  module Transaction
    extend self

    class Base
      attr_reader :session

      def initialize(session)
        @session = session
        @parent = session_transaction_stack.last
        session_transaction_stack << self
      end

      def inspect
        status_string = [:nesting_level, :failed?, :active?].map do |method|
          "#{method}: #{send(method)}"
        end.join(', ')

        "<#{self.class} [#{status_string}]"
      end

      alias failure mark_failed

      # Commits or marks this transaction for rollback, depending on whether #mark_failed has been previously invoked.
      def close
        fail 'Cannot commit transaction, already committed' if session_transaction_stack.empty?

        session_transaction_stack.pop

        post_close!
      end

      def delete
        fail 'not implemented'
      end

      def commit
        fail 'not implemented'
      end

      alias failure? failed?

      def autoclosed!
        @autoclosed = true if transient_failures_autoclose?
      end

      # Marks this transaction as failed,
      # which means that it will unconditionally be rolled back
      # when #close is called.
      # Aliased for legacy purposes.
      def mark_failed
        @parent.mark_failed if @parent
        @failure = true
      end
      alias_method :failure, :mark_failed

      # If it has been marked as failed.
      # Aliased for legacy purposes.
      def failed?
        !!@failure
      end
      alias_method :failure?, :failed?

      def mark_expired
        @parent.mark_expired if @parent
        @expired = true
      end

      def expired?
        !!@expired
      end

      private

      def transient_failures_autoclose?
        @session.version >= '2.2.6'
      end

      def autoclosed?
        !!@autoclosed
      end

      def active?
        session_transaction_stack.last == self
      end

      def nesting_level
        stack_index + 1
      end

      def stack_index
        session_transaction_stack.index(self)
      end

      def session_transaction_stack
        Transaction.transaction_stack_for(@session)
      end

      def post_close!
        return if autoclosed?
        if failed?
          delete
        else
          commit
        end
      end
    end

    # @return [Neo4j::Transaction::Instance]
    def new(session = Session.current!)
      session.transaction
    end

    # Runs the given block in a new transaction.
    # @param [Boolean] run_in_tx if true a new transaction will not be created, instead if will simply yield to the given block
    # @@yield [Neo4j::Transaction::Instance]
    def run(*args)
      session, run_in_tx = session_and_run_in_tx_from_args(args)

      fail ArgumentError, 'Expected a block to run in Transaction.run' unless block_given?

      return yield(nil) unless run_in_tx

      tx = Neo4j::Transaction.new(session)
      yield tx
    rescue Exception => e # rubocop:disable Lint/RescueException
      print_exception_cause(e)

      tx.mark_failed unless tx.nil?
      raise
    ensure
      tx.close unless tx.nil?
    end

    # To support old syntax of providing run_in_tx first
    # But session first is ideal
    def session_and_run_in_tx_from_args(args)
      fail ArgumentError, 'Too many arguments' if args.size > 2

      if args.empty?
        [Session.current!, true]
      else
        result = args.dup
        if result.size == 1
          result << ([true, false].include?(args[0]) ? Session.current! : true)
        end

        [true, false].include?(result[0]) ? result.reverse : result
      end
    end

    def current_for(session)
      transaction_stack_for(session).last
    end

    def root_for(session)
      transaction_stack_for(session).first
    end

    def transaction_stack_for(session)
      fail ArgumentError, 'No session specified' if session.nil?

      stack = session.instance_variable_get('@_transaction_stack')

      stack ||= []

      session.instance_variable_set('@_transaction_stack', stack)

      stack
    end

    private

    def print_exception_cause(exception)
      return if !exception.respond_to?(:cause) || !exception.cause.respond_to?(:print_stack_trace)

      puts "Java Exception in a transaction, cause: #{exception.cause}"
      exception.cause.print_stack_trace
    end
  end
end
