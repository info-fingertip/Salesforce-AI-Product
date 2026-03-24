/**
 * @description Test class for HelloWorld
 */
@isTest
private class HelloWorldTest {

    @isTest
    static void testSayHelloWithNull() {
        String result = HelloWorld.sayHello(null);
        System.assertEquals('Hello, World!', result, 'Null input should return default greeting');
    }

    @isTest
    static void testSayHelloWithBlank() {
        String result = HelloWorld.sayHello('');
        System.assertEquals('Hello, World!', result, 'Blank input should return default greeting');
    }

    @isTest
    static void testSayHelloWithName() {
        String result = HelloWorld.sayHello('Salesforce');
        System.assertEquals('Hello, Salesforce!', result, 'Should return personalized greeting');
    }
}