job('DSL-Tutorial-1-Test') {
    scm {
        git('git://github.com/quidryan/aws-sdk-test.git')
    }

    steps {
        maven('-e clean test')
    }
}