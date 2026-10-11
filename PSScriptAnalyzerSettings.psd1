@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Resik is an interactive console tool; host output is intentional and
        # kept separate from the pipeline objects that functions return.
        'PSAvoidUsingWriteHost'
    )
}
